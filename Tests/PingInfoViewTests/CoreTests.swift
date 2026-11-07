import Foundation
import Testing
@testable import PingInfoView

@Test func plainHostsAndTCPPort() {
    let result = HostParser.parse("1.1.1.1 example.com, example.com:443\n# skip", options: ParseOptions(mode: .plain))
    #expect(result.targets.map(\.host) == ["1.1.1.1", "example.com", "example.com"])
    #expect(result.targets[2].port == 443)
    #expect(result.warnings.isEmpty)
}

@Test func descriptionsGroupsCommentsAndShorthandRange() {
    let text = """
    # comment
    Group: Office
    192.168.0.10 Main Server
    192.168.0.11-13 Workstation
    #192.168.0.14 Hidden
    """
    let result = HostParser.parse(text, options: ParseOptions(mode: .described))
    #expect(result.targets.map(\.host) == ["192.168.0.10", "192.168.0.11", "192.168.0.12", "192.168.0.13"])
    #expect(result.targets.map(\.description) == ["Main Server", "Workstation", "Workstation", "Workstation"])
    #expect(result.targets.map(\.group) == ["Office", "Office", "Office", "Office"])
    #expect(result.targets.map(\.order) == [1, 2, 3, 4])
}

@Test func cidrSkipAndLimit() {
    var options = ParseOptions(skipFirstInCIDR: true, skipLastInCIDR: true)
    let small = HostParser.parse("10.0.0.0/30", options: options)
    #expect(small.targets.map(\.host) == ["10.0.0.1", "10.0.0.2"])

    options.expansionLimit = 16
    let huge = HostParser.parse("10.0.0.0/8", options: options)
    #expect(huge.targets.isEmpty)
    #expect(!huge.warnings.isEmpty)
}

@Test func ipv6LiteralAndBrackets() {
    let allowed = HostParser.parse("[2001:db8::1]:443 fe80::1", options: ParseOptions(mode: .plain))
    #expect(allowed.warnings.isEmpty)
    #expect(allowed.targets.map(\.host) == ["2001:db8::1", "fe80::1"])
    #expect(allowed.targets[0].port == 443)
}

@Test func automaticFormatDetectsGroups() {
    let parsed = HostParser.parse("Group: DNS\n1.1.1.1 Cloudflare DNS\n", options: ParseOptions(mode: .automatic))
    #expect(parsed.targets.count == 1)
    #expect(parsed.targets[0].description == "Cloudflare DNS")
}

@Test func statsStreakRecoveryAndHistory() {
    var settings = AppSettings()
    settings.alertAfterConsecutive = 2
    settings.beepOnFailed = true
    settings.beepOnSuccessAfterFailure = true
    settings.failureCommand = "say down"
    settings.successCommand = "say up"
    settings.lowerPaneMode = .statusChange
    var record = HostRecord(target: ParsedTarget(host: "10.0.0.1", port: nil, description: "", group: "", order: 1))

    let first = record.ingest(sample(false, 1), settings: settings)
    #expect(!first.beepFailure)
    #expect(!first.runFailureCommand)
    #expect(record.consecutiveFailed == 1)

    let second = record.ingest(sample(false, 2), settings: settings)
    #expect(second.beepFailure)
    #expect(second.runFailureCommand)
    #expect(record.history.count == 1)
    #expect(record.history[0].count == 2)
    #expect(record.maxConsecutiveFailed == 2)

    let third = record.ingest(sample(true, 12.5), settings: settings)
    #expect(third.beepRecovery)
    #expect(third.runRecoveryCommand)
    #expect(record.consecutiveFailed == 2)
    #expect(record.currentStreak == 0)
    #expect(record.succeeded == 1)
    #expect(record.averageMs == 12.5)
    #expect(abs(record.percentFailed - (200.0 / 3.0)) < 0.001)
    #expect(record.history.count == 2)
}

@Test func mergeKeepsCountersWhenDescriptionChanges() {
    var existing = HostRecord(target: ParsedTarget(host: "Example.com", port: 443, description: "Old", group: "Web", order: 1))
    existing.succeeded = 4
    let parsed = [ParsedTarget(host: "example.com", port: 443, description: "New", group: "Web", order: 9)]
    let merged = HostMerge.merge(existing: [existing], parsed: parsed)
    #expect(merged.count == 1)
    #expect(merged[0].id == existing.id)
    #expect(merged[0].succeeded == 4)
    #expect(merged[0].target.description == "New")
    #expect(merged[0].target.order == 1)
}

@Test func pingReportParser() {
    let success = """
    PING 127.0.0.1 (127.0.0.1): 32 data bytes
    40 bytes from 127.0.0.1: icmp_seq=0 ttl=64 time=0.183 ms
    1 packets transmitted, 1 packets received, 0.0% packet loss
    """
    let parsed = PingReportParser.parse(success)
    #expect(parsed.success)
    #expect(abs((parsed.latencyMs ?? 0) - 0.183) < 0.0001)
    #expect(parsed.ttl == 64)
    #expect(parsed.replyAddress == "127.0.0.1")
    #expect(parsed.address == "127.0.0.1")

    let unreachable = """
    PING 192.0.2.1 (192.0.2.1): 32 data bytes
    36 bytes from 192.245.162.241: Destination Host Unreachable
    1 packets transmitted, 0 packets received, 100.0% packet loss
    """
    let failed = PingReportParser.parse(unreachable)
    #expect(!failed.success)
    #expect(failed.address == "192.0.2.1")
    #expect(failed.latencyMs == nil)
    #expect(failed.error == "Host unreachable")

    let ipv6 = """
    PING6(56=40+8+8 bytes) ::1 --> ::1
    16 bytes from ::1, icmp_seq=0 hlim=64 time=0.139 ms
    1 packets transmitted, 1 packets received, 0.0% packet loss
    """
    let v6 = PingReportParser.parse(ipv6)
    #expect(v6.success)
    #expect(v6.ttl == 64)
    #expect(v6.replyAddress == "::1")
    #expect(v6.address == "::1")
}

@Test func exportEscapingAndSettingsDefaults() throws {
    var record = HostRecord(target: ParsedTarget(host: "host", port: nil, description: "A, \"quote\"", group: "", order: 1))
    record.succeeded = 1
    record.sent = 1
    record.lastStatus = .up
    let csv = Exporter.render(
        records: [record],
        format: .csv,
        options: ExportOptions(columns: [.hostName, .description], includeHeader: true, display: DisplayFormat(highResolution: true, useGMT: false))
    )
    #expect(csv.contains("\"A, \"\"quote\"\"\""))
    let xml = Exporter.render(records: [record], format: .xml, options: ExportOptions.from(AppSettings(), columns: [.description]))
    #expect(xml.contains("&quot;quote&quot;"))
    #expect(xml.contains(Brand.author))

    let decoded = try AppSettings.decodeStored(Data("{\"intervalSeconds\":5}".utf8))
    #expect(decoded.intervalSeconds == 5)
    #expect(decoded.timeoutMs == AppSettings().timeoutMs)
    #expect(!decoded.clearResultsOnStart)
    let freshScan = try AppSettings.decodeStored(Data("{\"clearResultsOnStart\":true}".utf8))
    #expect(freshScan.clearResultsOnStart)
    #expect(try AppSettings.decodeStored(Data("{}".utf8)) == AppSettings().normalized())

    let older = try AppSettings.decodeStored(Data("{\"maxConcurrent\":50,\"expansionLimit\":4096}".utf8))
    #expect(older.maxConcurrent == 200)
    #expect(older.expansionLimit == 65_536)
    #expect(older.attempts == 2)
    #expect(older.findLocalNames)
    let chosen = try AppSettings.decodeStored(Data("{\"maxConcurrent\":50,\"attempts\":1}".utf8))
    #expect(chosen.maxConcurrent == 50)
    #expect(chosen.attempts == 1)
}

@Test func icmpPacketsBuildAndParse() {
    #expect(ICMPPacket.checksum([0x45, 0x00, 0x00, 0x1c]) == ~UInt16(0x451c))
    let payload = ICMPPacket.payload(size: 32, token: 0xA1B2C3D4)
    #expect(payload.count == 32)
    #expect(ICMPPacket.token(in: payload) == 0xA1B2C3D4)
    let request = ICMPPacket.echoRequest(ipv6: false, identifier: 0x1234, sequence: 7, payload: payload)
    #expect(ICMPPacket.checksum(request) == 0)

    var reply = request
    reply[0] = ICMPPacket.echoReplyV4
    let header: [UInt8] = [0x45, 0, 0, 60, 0, 0, 0, 0, 57, 1, 0, 0, 8, 8, 8, 8, 192, 168, 1, 2]
    #expect(ICMPPacket.parse(header + reply, ipv6: false) == .reply(identifier: 0x1234, sequence: 7, ttl: 57, payload: payload))
    #expect(ICMPPacket.parse(reply, ipv6: false) == .reply(identifier: 0x1234, sequence: 7, ttl: nil, payload: payload))

    let unreachable: [UInt8] = [3, 1, 0, 0, 0, 0, 0, 0] + [0x45, 0, 0, 60, 0, 0, 0, 0, 64, 1, 0, 0, 192, 168, 1, 2, 10, 0, 0, 9] + Array(request.prefix(8))
    #expect(ICMPPacket.parse(header + unreachable, ipv6: false) == .failure(identifier: 0x1234, sequence: 7, message: "Host unreachable"))

    let v6 = ICMPPacket.echoRequest(ipv6: true, identifier: 1, sequence: 2, payload: [9, 9, 9, 9])
    var v6Reply = v6
    v6Reply[0] = ICMPPacket.echoReplyV6
    #expect(ICMPPacket.parse(v6Reply, ipv6: true, hopLimit: 64) == .reply(identifier: 1, sequence: 2, ttl: 64, payload: [9, 9, 9, 9]))
}

@Test func localNameProtocols() {
    let encoded = NetBIOS.encodedName("ab")
    #expect(encoded.count == 34)
    #expect(encoded.first == 0x20 && encoded.last == 0)
    #expect(Array(encoded[1...4]) == Array("EBEC".utf8))
    #expect(Array(encoded[5...6]) == Array("CA".utf8))
    #expect(Array(encoded[31...32]) == Array("AA".utf8))

    let id: UInt16 = 0x0102
    let query = NetBIOS.nameQuery("ab", id: id)
    var response = Array(query.prefix(12))
    response[2] = 0x85
    response[3] = 0x00
    response[4] = 0; response[5] = 0
    response[6] = 0; response[7] = 1
    response += encoded + [0, 0x20, 0, 1, 0, 0, 1, 0, 0, 6, 0, 0, 192, 168, 1, 50]
    #expect(NetBIOS.address(in: response, id: id) == "192.168.1.50")
    #expect(NetBIOS.address(in: response, id: id &+ 1) == nil)

    var status = Array(query.prefix(12))
    status[2] = 0x84; status[3] = 0
    status[4] = 0; status[5] = 0
    status[6] = 0; status[7] = 1
    let entry = Array("NAS-BOX".utf8) + [UInt8](repeating: 0x20, count: 8) + [0x00, 0x04, 0x00]
    let group = Array("WORKGROUP".utf8) + [UInt8](repeating: 0x20, count: 6) + [0x00, 0x84, 0x00]
    let body: [UInt8] = [2] + group + entry
    status += NetBIOS.encodedName("", wildcard: true) + [0, 0x21, 0, 1, 0, 0, 0, 0, 0, UInt8(body.count)] + body
    #expect(NetBIOS.machineName(in: status, id: id) == "NAS-BOX")

    let llmnr = LLMNR.packet("printer", id: 9)
    #expect(llmnr.count == 12 + 1 + 7 + 1 + 4)
    var answer = llmnr
    answer[2] = 0x80
    answer[6] = 0; answer[7] = 1
    answer += [0xC0, 0x0C, 0, 1, 0, 1, 0, 0, 0, 30, 0, 4, 10, 0, 0, 7]
    #expect(LLMNR.answer(answer, id: 9) == "10.0.0.7")
    #expect(NetworkErrors.isPrivateIPv4("192.168.1.1"))
    #expect(NetworkErrors.isPrivateIPv4("172.20.0.1"))
    #expect(!NetworkErrors.isPrivateIPv4("8.8.8.8"))
}

@Test func namesResolveWithoutBlocking() async {
    #expect(await NameResolver.resolve("127.0.0.1", preferIPv6: false, findLocalNames: true, timeoutMs: 500)?.source == .literal)
    #expect(await NameResolver.resolve("localhost", preferIPv6: false, findLocalNames: false, timeoutMs: 2000)?.address == "127.0.0.1")
    #expect(await NameResolver.resolve("[::1]", preferIPv6: false, findLocalNames: false, timeoutMs: 500)?.address == "::1")
}

@Test func commandQuotingAndLaunchOptions() {
    var record = HostRecord(target: ParsedTarget(host: "web", port: nil, description: "O'Hare", group: "", order: 2))
    record.resolvedAddress = "203.0.113.5"
    let command = CommandTemplate.render("say %HostName% %Description%", record: record, format: AppSettings().displayFormat)
    #expect(command == "say 'web' 'O'\\''Hare'")

    let options = LaunchOptions.parse(["/loadfile", "/Users/me/hosts.txt", "/scomma", "/tmp/out.csv", "/PingTimeout", "1500", "/IPv6", "1"])
    #expect(options.requestsHeadless)
    #expect(options.loadFile == "/Users/me/hosts.txt")
    #expect(options.outputs.first?.0 == .csv)
    #expect(options.timeoutMs == 1500)
    #expect(options.allowIPv6 == true)
    #expect(!LaunchOptions.parse(["-psn_0_123"]).requestsHeadless)
}

@Test func customMenuAndPathTokens() {
    let menu = CustomMenuFile.parse("""
    [CustomMenu]
    Caption0=Ping IP
    Command0=ping %IPAddress%
    Caption1=-
    """)
    #expect(menu.count == 2)
    #expect(!menu[0].isSeparator)
    #expect(menu[1].isSeparator)
    let path = PathTokens.expand("~/ping-{date}.csv")
    #expect(!path.contains("~"))
    #expect(!path.contains("{date}"))
    #expect(path.hasSuffix(".csv"))
}

@Test func localICMP() async {
    let request = PingRequest(
        destination: "127.0.0.1",
        port: nil,
        timeoutMs: 1000,
        payloadSize: 32,
        ttl: 0,
        dontFragment: false,
        allowIPv6: false,
        sourceAddress: ""
    )
    let sample = await PingService.probe(request)
    #expect(sample.success, "\(sample.error ?? "no error")")
    #expect(sample.address == "127.0.0.1")
    #expect(sample.latencyMs != nil)
    #expect(sample.ttl == 64)
}

@Test func localICMPv6() async {
    let request = PingRequest(
        destination: "::1",
        port: nil,
        timeoutMs: 1000,
        payloadSize: 32,
        ttl: 0,
        dontFragment: false,
        allowIPv6: true,
        sourceAddress: ""
    )
    let sample = await PingService.probe(request)
    #expect(sample.success, "\(sample.error ?? "no error")")
    #expect(sample.address == "::1")
}

@Test func refusedTCPPortFailsFast() async {
    let request = PingRequest(
        destination: "127.0.0.1",
        port: 1,
        timeoutMs: 2000,
        payloadSize: 32,
        ttl: 0,
        dontFragment: false,
        allowIPv6: false,
        sourceAddress: ""
    )
    let started = Date()
    let sample = await PingService.probe(request)
    #expect(!sample.success)
    #expect(sample.error == "Connection refused")
    #expect(sample.address == "127.0.0.1")
    #expect(Date().timeIntervalSince(started) < 1.5)
}

@Test func pingArgumentsMatchEachTool() {
    let request = PingRequest(
        destination: "x",
        port: nil,
        timeoutMs: 1500,
        payloadSize: 64,
        ttl: 30,
        dontFragment: true,
        allowIPv6: true,
        sourceAddress: ""
    )
    let v6 = PingArguments.make(ipv6: true, host: "::1", request: request)
    #expect(!v6.contains("-W"))
    #expect(!v6.contains("-m"))
    #expect(v6.contains("-h"))
    #expect(v6.last == "::1")
    let v4 = PingArguments.make(ipv6: false, host: "127.0.0.1", request: request)
    #expect(v4.contains("-W"))
    #expect(v4.contains("-m"))
    #expect(v4.contains("-D"))
    #expect(v4.last == "127.0.0.1")
}

@Test func hostsIPsFQDNsAndSimpleNames() {
    let parsed = HostParser.parse(
        "router printer\nfileserver.example.com\nhttps://example.com/status 10.1.1.1/\nserver.example.com.",
        options: ParseOptions(mode: .automatic)
    )
    #expect(parsed.warnings.isEmpty)
    #expect(parsed.targets.map(\.host) == ["router", "printer", "fileserver.example.com", "example.com", "10.1.1.1", "server.example.com"])

    let port = HostParser.parse("https://example.com:443/health", options: ParseOptions(mode: .plain))
    #expect(port.targets.map(\.host) == ["example.com"])
    #expect(port.targets[0].port == 443)
    #expect(HostParser.parse("10.0.0.0/30", options: ParseOptions()).targets.map(\.host) == ["10.0.0.0", "10.0.0.1", "10.0.0.2", "10.0.0.3"])
}

@Test func automaticFormatSeesDescriptionsWithoutGroups() {
    let described = HostParser.parse("1.1.1.1 Cloudflare\n8.8.8.8 Google DNS", options: ParseOptions(mode: .described))
    #expect(described.targets.map(\.host) == ["1.1.1.1", "8.8.8.8"])
    #expect(described.targets.map(\.description) == ["Cloudflare", "Google DNS"])

    let plain = HostParser.parse("1.1.1.1 8.8.8.8 example.com router", options: ParseOptions(mode: .automatic))
    #expect(plain.targets.map(\.host) == ["1.1.1.1", "8.8.8.8", "example.com", "router"])
}

@Test func columnsFitWithoutSideScrolling() {
    let specs = ColumnID.allCases.map { ColumnSpec(id: $0, minWidth: $0.minWidth, weight: $0.weight, priority: $0.priority) }
    for width in [320.0, 560.0, 900.0, 1440.0, 2560.0] as [CGFloat] {
        let fit = ColumnLayout.fit(specs, into: width)
        let total = fit.columns.reduce(0) { $0 + $1.width }
        #expect(total == width)
        #expect(fit.columns.count + fit.hidden.count == specs.count)
        #expect(fit.columns.contains { $0.id == .hostName })
    }
    let narrow = ColumnLayout.fit(specs, into: 560)
    #expect(narrow.columns.contains { $0.id == .status })
    #expect(narrow.hidden.contains(.order))
    #expect(ColumnLayout.fit(specs, into: 5000).hidden.isEmpty)
}

@Test func selectionRangesAndKeyboard() {
    let rows = [UUID(), UUID(), UUID(), UUID(), UUID()]
    var selection = RowSelection()
    selection.click(rows[1], command: false, shift: false, order: rows)
    selection.click(rows[3], command: false, shift: true, order: rows)
    #expect(selection.ids == Set(rows[1...3]))
    #expect(selection.anchor == rows[1])
    #expect(selection.lead == rows[3])

    selection.click(rows[0], command: true, shift: false, order: rows)
    #expect(selection.ids == Set([rows[0], rows[1], rows[2], rows[3]]))
    #expect(selection.lead == rows[0])

    selection.click(rows[4], command: true, shift: true, order: rows)
    #expect(selection.ids == Set(rows))

    selection.click(rows[2], command: false, shift: false, order: rows)
    selection.move(by: 1, extending: true, order: rows)
    selection.move(by: 1, extending: true, order: rows)
    #expect(selection.ids == Set(rows[2...4]))
    selection.move(by: -1, extending: true, order: rows)
    #expect(selection.ids == Set(rows[2...3]))

    selection.move(by: 1, extending: false, order: rows)
    #expect(selection.ids == [rows[4]])

    selection.jump(toEnd: false, extending: true, order: rows)
    #expect(selection.ids == Set(rows))
    #expect(selection.lead == rows[0])
    selection.selectAll(rows)
    #expect(selection.ids.count == rows.count)
    selection.clear()
    #expect(selection.ids.isEmpty)
}

@Test func typeAheadWalksMatches() {
    let names = ["dns", "edge", "example", "extra", "mail"]
    #expect(TypeAhead.match(buffer: "e", names: names, lead: nil, continuing: false) == 1)
    #expect(TypeAhead.match(buffer: "e", names: names, lead: 1, continuing: false) == 2)
    #expect(TypeAhead.match(buffer: "e", names: names, lead: 4, continuing: false) == 1)
    #expect(TypeAhead.match(buffer: "ex", names: names, lead: 2, continuing: true) == 2)
    #expect(TypeAhead.match(buffer: "z", names: names, lead: 0, continuing: false) == nil)
}

@Test func brandingIsFixed() {
    #expect(Brand.appName == "PingInfoView")
    #expect(Brand.version == "1.3.1")
    #expect(Brand.build == "4")
    #expect(Brand.author == "Sumit Kumawat")
    #expect(Brand.website == "www.sumitkumawat.com")
    #expect(Brand.websiteURL.absoluteString == "https://www.sumitkumawat.com")
    #expect(Brand.email == "hello@sumitkumawat.com")
    #expect(Brand.mailtoURL.absoluteString == "mailto:hello@sumitkumawat.com")
    #expect(Brand.bundleIdentifier == "com.sumitkumawat.pinginfoview")
    #expect(Brand.creditLine == "Sumit Kumawat · www.sumitkumawat.com · hello@sumitkumawat.com")
}

private func sample(_ success: Bool, _ latency: Double) -> PingSample {
    PingSample(
        success: success,
        latencyMs: success ? latency : nil,
        ttl: success ? 64 : nil,
        replyAddress: success ? "10.0.0.1" : nil,
        address: "10.0.0.1",
        error: success ? nil : "Timeout",
        sentAt: Date(timeIntervalSince1970: latency)
    )
}

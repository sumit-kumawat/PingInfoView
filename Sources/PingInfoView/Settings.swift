import Foundation

enum HostListFormat: String, Codable, CaseIterable, Identifiable, Sendable {
    case automatic
    case plain
    case described

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: "Automatic"
        case .plain: "Hosts only"
        case .described: "IP and description"
        }
    }
}

enum LowerPaneMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case all
    case failedOnly
    case statusChange
    case off

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "Every ping"
        case .failedOnly: "Failed pings only"
        case .statusChange: "Status changes"
        case .off: "Don't keep history"
        }
    }
}

enum LogMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case off
    case all
    case failedOnly

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: "Off"
        case .all: "All pings"
        case .failedOnly: "Failed pings only"
        }
    }
}

enum ExportFormat: String, Codable, CaseIterable, Identifiable, Sendable {
    case text
    case tab
    case csv
    case tabular
    case html
    case verticalHTML
    case xml

    var id: String { rawValue }

    var title: String {
        switch self {
        case .text: "Text"
        case .tab: "Tab-delimited"
        case .csv: "CSV"
        case .tabular: "Tabular text"
        case .html: "HTML"
        case .verticalHTML: "HTML (vertical)"
        case .xml: "XML"
        }
    }

    var fileExtension: String {
        switch self {
        case .text, .tab, .tabular: "txt"
        case .csv: "csv"
        case .html, .verticalHTML: "html"
        case .xml: "xml"
        }
    }

    var separator: String {
        switch self {
        case .tab: "\t"
        case .csv: ","
        default: ","
        }
    }
}

enum DisplayMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case all
    case up
    case down

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "All hosts"
        case .up: "Succeeded only"
        case .down: "Failed only"
        }
    }
}

struct ParseOptions: Equatable, Sendable {
    var mode: HostListFormat = .automatic
    var skipFirstInCIDR = false
    var skipLastInCIDR = false
    var expansionLimit = 4096
    var allowIPv6 = false
}

struct AppSettings: Codable, Equatable, Sendable {
    var hostList: String = ""
    var hostListFormat: HostListFormat = .automatic
    var pingEvery: Bool = true
    var intervalSeconds: Int = 30
    var timeoutMs: Int = 2000
    var payloadSize: Int = 32
    var maxConcurrent: Int = 50
    var allowIPv6: Bool = false
    var resolveAddresses: Bool = true
    var resolveEveryPing: Bool = false
    var startImmediately: Bool = false
    /// When a scan starts, drop the current counts and history once. Later rounds in that scan keep the new counts.
    var clearResultsOnStart: Bool = false
    var windowTitle: String = ""
    var ttl: Int = 0
    var dontFragment: Bool = false
    var sourceAddress: String = ""
    var beepOnFailed: Bool = false
    var beepOnSuccessAfterFailure: Bool = false
    var soundName: String = "Ping"
    var alertAfterConsecutive: Int = 1
    var failureCommand: String = ""
    var successCommand: String = ""
    var lowerPaneMode: LowerPaneMode = .all
    var showLowerPane: Bool = true
    var historyLimit: Int = 2000
    var autoExportEnabled: Bool = false
    var autoExportSeconds: Int = 60
    var autoExportFormat: ExportFormat = .csv
    var autoExportPath: String = ""
    var logMode: LogMode = .off
    var logPath: String = ""
    var includeExportHeader: Bool = true
    var skipFirstInCIDR: Bool = false
    var skipLastInCIDR: Bool = false
    var expansionLimit: Int = 4096
    var alwaysOnTop: Bool = false
    var menuBarIcon: Bool = false
    var startHidden: Bool = false
    var sortOnEveryUpdate: Bool = false
    var autoScrollLowerPane: Bool = true
    var blackBackground: Bool = false
    var alternateRows: Bool = true
    var hideDisabled: Bool = false
    var displayMode: DisplayMode = .all
    var highResolutionTime: Bool = true
    var useGMT: Bool = false
    var fontSize: Double = 13
    var visibleColumns: [String] = ColumnID.defaultVisible.map(\.rawValue)
    var didConfigure: Bool = false

    var parseOptions: ParseOptions {
        ParseOptions(
            mode: hostListFormat,
            skipFirstInCIDR: skipFirstInCIDR,
            skipLastInCIDR: skipLastInCIDR,
            expansionLimit: expansionLimit,
            allowIPv6: allowIPv6
        )
    }

    var displayFormat: DisplayFormat {
        DisplayFormat(highResolution: highResolutionTime, useGMT: useGMT)
    }

    var columns: [ColumnID] {
        let known = Set(visibleColumns)
        let selected = ColumnID.allCases.filter { known.contains($0.rawValue) }
        return selected.isEmpty ? ColumnID.defaultVisible : selected
    }

    func normalized() -> AppSettings {
        var copy = self
        copy.intervalSeconds = copy.intervalSeconds.clamped(to: 1...86_400)
        copy.timeoutMs = copy.timeoutMs.clamped(to: 100...120_000)
        copy.payloadSize = copy.payloadSize.clamped(to: 0...65_507)
        copy.maxConcurrent = copy.maxConcurrent.clamped(to: 1...500)
        copy.alertAfterConsecutive = copy.alertAfterConsecutive.clamped(to: 1...100_000)
        copy.historyLimit = copy.historyLimit.clamped(to: 10...200_000)
        copy.autoExportSeconds = copy.autoExportSeconds.clamped(to: 1...86_400)
        copy.fontSize = copy.fontSize.clamped(to: 10...22)
        copy.ttl = copy.ttl.clamped(to: 0...255)
        copy.expansionLimit = copy.expansionLimit.clamped(to: 1...65_536)
        copy.hostList = copy.hostList.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        if copy.visibleColumns.isEmpty {
            copy.visibleColumns = ColumnID.defaultVisible.map(\.rawValue)
        }
        if copy.startHidden && !copy.menuBarIcon {
            copy.startHidden = false
        }
        let allowedSounds = Set(SoundCatalog.names)
        if !allowedSounds.contains(copy.soundName) {
            copy.soundName = "Ping"
        }
        return copy
    }

    static func decodeStored(_ data: Data) throws -> AppSettings {
        let defaults = try JSONEncoder().encode(AppSettings())
        guard var base = try JSONSerialization.jsonObject(with: defaults) as? [String: Any] else {
            return AppSettings()
        }
        if let patch = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for (key, value) in patch where !(value is NSNull) {
                base[key] = value
            }
        }
        let merged = try JSONSerialization.data(withJSONObject: base)
        return try JSONDecoder().decode(AppSettings.self, from: merged).normalized()
    }
}

enum SoundCatalog {
    static let names = [
        "System", "Basso", "Blow", "Bottle", "Frog", "Funk", "Glass",
        "Hero", "Morse", "Ping", "Pop", "Purr", "Sosumi", "Submarine", "Tink"
    ]
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

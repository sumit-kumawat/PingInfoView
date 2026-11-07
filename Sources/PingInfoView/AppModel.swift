import AppKit
import Foundation

enum LaunchBridge {
    nonisolated(unsafe) static var options = LaunchOptions()
}

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published var settings: AppSettings
    @Published var records: [HostRecord] = []
    @Published var warnings: [String] = []
    @Published var status = "Ready"
    @Published var running = false
    @Published var showOptions = false
    @Published var showHelp = false
    @Published var query = ""
    @Published var groupFilter = "All"
    @Published var selection: Set<UUID> = []
    @Published var selectionAnchor: UUID?
    @Published var selectionLead: UUID?
    @Published var sortColumn: ColumnID = .order
    @Published var sortAscending = true
    @Published var collapsedGroups: Set<String> = []
    @Published var roundIndex = 0
    @Published var lastRoundSeconds: Double?
    @Published var customMenu: [CustomMenuItem] = []
    /// macOS refused to send to a private address in the last round, which means Local Network access is off.
    @Published var localNetworkBlocked = false

    var openMainWindow: (() -> Void)?
    var focusTable: (() -> Void)?

    private var frozenRank: [UUID: Int] = [:]
    private var monitorTask: Task<Void, Never>?
    private var generation = UUID()
    private var activity: NSObjectProtocol?
    private var lifetimeActivity: NSObjectProtocol?
    private var lastBeep = Date.distantPast
    private var lastAutoExport: Date?
    private var reportedLogError = false
    private var typeBuffer = ""
    private var typeAt = Date.distantPast
    private let statusItem = StatusItemController()

    private init() {
        if let data = try? Data(contentsOf: SupportPaths.settings),
           let stored = try? AppSettings.decodeStored(data) {
            settings = stored
        } else {
            settings = AppSettings()
        }
        statusItem.onShow = { [weak self] in self?.showMainWindow() }
        statusItem.onStart = { [weak self] in self?.start() }
        statusItem.onNewScan = { [weak self] in self?.newScan() }
        statusItem.onStop = { [weak self] in self?.stop() }
        statusItem.onAbout = { AboutPanel.show() }
    }

    var effectiveTitle: String {
        let custom = settings.windowTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return custom.isEmpty ? Brand.appName : "\(Brand.appName) — \(custom)"
    }

    var groupNames: [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for record in records where !record.target.group.isEmpty && seen.insert(record.target.group).inserted {
            ordered.append(record.target.group)
        }
        return ordered
    }

    var upCount: Int { records.reduce(0) { $0 + ($1.enabled && $1.lastStatus == .up ? 1 : 0) } }
    var downCount: Int { records.reduce(0) { $0 + ($1.enabled && $1.lastStatus == .down ? 1 : 0) } }
    var disabledCount: Int { records.reduce(0) { $0 + ($1.enabled ? 0 : 1) } }

    var summary: String {
        var parts = ["\(records.count) hosts", "\(upCount) up", "\(downCount) down"]
        if disabledCount > 0 { parts.append("\(disabledCount) disabled") }
        if !selection.isEmpty { parts.append("\(selection.count) selected") }
        if let lastRoundSeconds {
            parts.append(String(format: "round %.1fs", locale: Locale(identifier: "en_US_POSIX"), lastRoundSeconds))
        }
        return parts.joined(separator: " · ")
    }

    var displayedRecords: [HostRecord] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let rows = records.filter { record in
            if settings.hideDisabled && !record.enabled { return false }
            switch settings.displayMode {
            case .all:
                break
            case .up:
                if !record.enabled || record.lastStatus != .up { return false }
            case .down:
                if !record.enabled || record.lastStatus != .down { return false }
            }
            if groupFilter != "All" && record.target.group != groupFilter { return false }
            if !needle.isEmpty {
                let haystack = [
                    record.hostNameText, record.ipText, record.target.description,
                    record.target.host, record.target.group, record.replyAddress ?? "", record.lastError ?? ""
                ].joined(separator: " ").lowercased()
                if !haystack.contains(needle) { return false }
            }
            return true
        }
        if settings.sortOnEveryUpdate || frozenRank.isEmpty {
            return sorted(rows)
        }
        return rows.sorted { lhs, rhs in
            let left = frozenRank[lhs.id] ?? Int.max
            let right = frozenRank[rhs.id] ?? Int.max
            return left == right ? lhs.target.order < rhs.target.order : left < right
        }
    }

    /// Rows the user can move through. Hosts inside a collapsed group stay out of keyboard and Shift-click ranges.
    var visibleRows: [HostRecord] {
        let rows = displayedRecords
        let grouped = (sortColumn == .order || sortColumn == .group) && rows.contains { !$0.target.group.isEmpty }
        guard grouped else { return rows }
        return rows.filter { record in
            let name = record.target.group.isEmpty ? TableSection.ungrouped : record.target.group
            return !collapsedGroups.contains(name)
        }
    }

    private func sorted(_ rows: [HostRecord]) -> [HostRecord] {
        let column = sortColumn
        let ascending = sortAscending
        return rows.sorted { lhs, rhs in
            let left = lhs.sortValue(for: column)
            let right = rhs.sortValue(for: column)
            if left == right { return lhs.target.order < rhs.target.order }
            return ascending ? left < right : right < left
        }
    }

    private func freezeOrder() {
        frozenRank = Dictionary(uniqueKeysWithValues: sorted(records).enumerated().map { ($1.id, $0) })
    }

    func launch() {
        if lifetimeActivity == nil {
            lifetimeActivity = ProcessInfo.processInfo.beginActivity(
                options: [.suddenTerminationDisabled, .automaticTerminationDisabled],
                reason: "\(Brand.appName) keeps monitoring available"
            )
        }
        let options = LaunchBridge.options
        var startNow = settings.startImmediately
        if options.loadFile != nil || !options.hostArguments.isEmpty {
            var text = ""
            if let loadFile = options.loadFile {
                let path = PathTokens.expand(loadFile)
                if let loaded = try? TextFile.read(URL(fileURLWithPath: path)) {
                    text = loaded
                } else {
                    status = "Could not read \(path)"
                }
            }
            if !options.hostArguments.isEmpty {
                if !text.isEmpty { text += "\n" }
                text += options.hostArguments.joined(separator: "\n")
            }
            var next = settings
            options.apply(to: &next)
            next.hostList = text
            next.didConfigure = true
            apply(next, preserveStats: false)
            startNow = options.startImmediately ?? true
        } else {
            var next = settings
            options.apply(to: &next)
            apply(next, preserveStats: false)
            startNow = options.startImmediately ?? settings.startImmediately
        }
        reloadCustomMenu()
        syncStatusItem()
        let hide = settings.menuBarIcon && settings.startHidden && startNow && !records.isEmpty
        if startNow && !records.isEmpty {
            start()
        } else if !hide {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.showOptions = true
            }
        }
        if hide {
            DispatchQueue.main.async { [weak self] in
                self?.hideWindows()
            }
        } else {
            NSApp.setActivationPolicy(.regular)
        }
    }

    func apply(_ newSettings: AppSettings, preserveStats: Bool) {
        let previous = settings
        let next = newSettings.normalized()
        settings = next
        saveSettings()
        let parsed = HostParser.parse(next.hostList, options: next.parseOptions)
        warnings = parsed.warnings
        records = preserveStats
            ? HostMerge.merge(existing: records, parsed: parsed.targets)
            : parsed.targets.map(HostRecord.init(target:))
        if !next.resolveAddresses {
            for index in records.indices {
                records[index].reverseName = nil
                records[index].didReverseLookup = false
            }
        }
        if previous.resolveEveryPing != next.resolveEveryPing || previous.allowIPv6 != next.allowIPv6
            || previous.findLocalNames != next.findLocalNames {
            NameResolver.clearCache()
            for index in records.indices where !HostParser.isIPAddress(records[index].target.host) {
                records[index].resolvedAddress = nil
            }
        }
        let ids = Set(records.map(\.id))
        selection = selection.intersection(ids)
        if let anchor = selectionAnchor, !ids.contains(anchor) {
            selectionAnchor = nil
        }
        if let lead = selectionLead, !ids.contains(lead) {
            selectionLead = selectionAnchor
        }
        if groupFilter != "All" && !groupNames.contains(groupFilter) {
            groupFilter = "All"
        }
        collapsedGroups = collapsedGroups.intersection(Set(groupNames + [TableSection.ungrouped]))
        if !frozenRank.isEmpty {
            freezeOrder()
        }
        if records.isEmpty {
            stop()
        }
        syncStatusItem()
    }

    func applyKeepingStats(_ draft: AppSettings) {
        apply(draft, preserveStats: true)
        status = running ? "Settings updated" : "Settings saved"
    }

    func applyAndStart(_ draft: AppSettings) {
        stop()
        apply(draft, preserveStats: true)
        if !records.isEmpty {
            start()
        }
    }

    func update<Value: Equatable>(_ keyPath: WritableKeyPath<AppSettings, Value>, to value: Value) {
        guard settings[keyPath: keyPath] != value else { return }
        var next = settings
        next[keyPath: keyPath] = value
        apply(next, preserveStats: true)
    }

    func start() {
        beginScan(clearingExisting: settings.clearResultsOnStart)
    }

    /// Clears the current counts and history once, then starts. Later rounds in this scan keep the new counts.
    func newScan() {
        beginScan(clearingExisting: true)
    }

    private func beginScan(clearingExisting: Bool) {
        if records.isEmpty {
            apply(settings, preserveStats: true)
        }
        guard records.contains(where: \.enabled) else {
            status = records.isEmpty ? "Add at least one host" : "All hosts are disabled"
            if records.isEmpty { showOptions = true }
            return
        }
        monitorTask?.cancel()
        let token = UUID()
        generation = token
        if clearingExisting {
            wipeResults()
        }
        running = true
        updateActivity()
        syncStatusItem()
        status = clearingExisting ? "New scan" : "Pinging"
        monitorTask = Task { @MainActor in
            await self.run(generation: token)
        }
    }

    func stop() {
        generation = UUID()
        monitorTask?.cancel()
        monitorTask = nil
        guard running else { return }
        running = false
        updateActivity()
        status = "Stopped"
        syncStatusItem()
    }

    func resetCounters() {
        wipeResults()
        status = "Counters reset"
        syncStatusItem()
    }

    private func wipeResults() {
        NameResolver.clearCache()
        localNetworkBlocked = false
        for index in records.indices {
            records[index].clearStats()
        }
        roundIndex = 0
        lastRoundSeconds = nil
        lastAutoExport = nil
    }

    func sort(by column: ColumnID) {
        if sortColumn == column {
            sortAscending.toggle()
        } else {
            sortColumn = column
            sortAscending = true
        }
        freezeOrder()
    }

    func toggleCollapsed(_ group: String) {
        if collapsedGroups.contains(group) {
            collapsedGroups.remove(group)
        } else {
            collapsedGroups.insert(group)
        }
    }

    func select(_ id: UUID, command: Bool, shift: Bool) {
        var next = currentSelection()
        next.click(id, command: command, shift: shift, order: visibleRows.map(\.id))
        commit(next)
        focusTable?()
    }

    func moveSelection(by offset: Int, extending: Bool) {
        var next = currentSelection()
        next.move(by: offset, extending: extending, order: visibleRows.map(\.id))
        commit(next)
        focusTable?()
    }

    func jumpSelection(toEnd: Bool, extending: Bool) {
        var next = currentSelection()
        next.jump(toEnd: toEnd, extending: extending, order: visibleRows.map(\.id))
        commit(next)
        focusTable?()
    }

    func selectAll() {
        var next = currentSelection()
        next.selectAll(visibleRows.map(\.id))
        commit(next)
        focusTable?()
    }

    func clearSelection() {
        var next = currentSelection()
        next.clear()
        commit(next)
    }

    func typeSelect(_ characters: String) {
        let now = Date()
        let continuing = now.timeIntervalSince(typeAt) <= 0.8 && !typeBuffer.isEmpty
        typeAt = now
        typeBuffer = continuing ? typeBuffer + characters.lowercased() : characters.lowercased()
        let rows = visibleRows
        let names = rows.map { row in
            [row.hostNameText, row.ipText, row.target.host].first { !$0.isEmpty && $0.lowercased().hasPrefix(typeBuffer) } ?? row.hostNameText
        }
        let leadIndex = selectionLead.flatMap { id in rows.firstIndex { $0.id == id } }
        guard let index = TypeAhead.match(buffer: typeBuffer, names: names, lead: leadIndex, continuing: continuing) else { return }
        select(rows[index].id, command: false, shift: false)
    }

    /// Collapses or expands the group of the current row. Returns false when the table is not grouped.
    func setLeadGroupCollapsed(_ collapsed: Bool) -> Bool {
        let grouped = sortColumn == .order || sortColumn == .group
        guard grouped, records.contains(where: { !$0.target.group.isEmpty }) else { return false }
        guard let id = selectionLead ?? selection.first, let record = records.first(where: { $0.id == id }) else { return false }
        let name = record.target.group.isEmpty ? TableSection.ungrouped : record.target.group
        if collapsed {
            collapsedGroups.insert(name)
        } else {
            collapsedGroups.remove(name)
        }
        return true
    }

    private func currentSelection() -> RowSelection {
        RowSelection(ids: selection, anchor: selectionAnchor, lead: selectionLead)
    }

    private func commit(_ next: RowSelection) {
        selection = next.ids
        selectionAnchor = next.anchor
        selectionLead = next.lead
    }

    func setEnabled(_ enabled: Bool, ids: Set<UUID>) {
        var changed = 0
        for index in records.indices where ids.contains(records[index].id) && records[index].enabled != enabled {
            records[index].enabled = enabled
            changed += 1
        }
        if changed > 0 {
            status = "\(enabled ? "Enabled" : "Disabled") \(changed) \(changed == 1 ? "host" : "hosts")"
            syncStatusItem()
        }
    }

    func records(for ids: Set<UUID>) -> [HostRecord] {
        displayedRecords.filter { ids.contains($0.id) }
    }

    var selectedOrVisible: [HostRecord] {
        let chosen = records(for: selection)
        return chosen.isEmpty ? displayedRecords : chosen
    }

    func loadHostFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Load"
        panel.message = "Choose a text file of host names or IP addresses"
        if panel.runModal() == .OK, let url = panel.url {
            importHostFile(url, replace: true)
        }
    }

    func importHostFile(_ url: URL, replace: Bool) {
        let text: String
        do {
            text = try TextFile.read(url)
        } catch {
            status = "Could not read \(url.lastPathComponent)"
            return
        }
        var next = settings
        let current = next.hostList.trimmingCharacters(in: .whitespacesAndNewlines)
        if replace || current.isEmpty {
            next.hostList = text
        } else {
            next.hostList += "\n" + text
        }
        next.didConfigure = true
        apply(next, preserveStats: true)
        showMainWindow()
        status = "Loaded \(url.lastPathComponent) · \(records.count) hosts"
    }

    func export(_ format: ExportFormat) {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "PingInfoView.\(format.fileExtension)"
        panel.title = "Export \(format.title)"
        panel.prompt = "Export"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let rows = selectedOrVisible
        do {
            try Exporter.write(
                records: rows,
                format: format,
                to: url.path,
                options: ExportOptions.from(settings, columns: settings.columns)
            )
            status = "Exported \(rows.count) \(rows.count == 1 ? "row" : "rows") to \(url.lastPathComponent)"
        } catch {
            status = error.localizedDescription
        }
    }

    func copySelectionOrVisible() {
        let chosen = records(for: selection)
        let everything = chosen.isEmpty
        let rows = everything ? displayedRecords : chosen
        guard !rows.isEmpty else { return }
        putOnClipboard(Exporter.clipboard(
            records: rows,
            columns: settings.columns,
            options: ExportOptions.from(settings, columns: settings.columns)
        ))
        if everything {
            status = "Copied all \(rows.count) visible \(rows.count == 1 ? "row" : "rows")"
        } else {
            status = "Copied \(rows.count) \(rows.count == 1 ? "row" : "rows")"
        }
    }

    func copyHostNames() {
        copyLines(selectedOrVisible.map(\.hostNameText), singular: "host name", plural: "host names")
    }

    func copyAddresses() {
        copyLines(selectedOrVisible.map { $0.ipText.isEmpty ? $0.target.host : $0.ipText }, singular: "address", plural: "addresses")
    }

    func copyHistory(_ record: HostRecord) {
        guard !record.history.isEmpty else { return }
        let format = settings.displayFormat
        var lines = ["Sent On\tStatus\tPing (ms)\tCount\tTTL\tReply\tDetail"]
        for entry in record.history {
            lines.append([
                entry.sentText(format: format),
                entry.success ? "Succeeded" : "Failed",
                format.milliseconds(entry.latencyMs),
                "\(entry.count)",
                entry.ttl.map(String.init) ?? "",
                entry.replyAddress ?? "",
                entry.error ?? ""
            ].joined(separator: "\t"))
        }
        putOnClipboard(lines.joined(separator: "\n"))
        status = "Copied \(record.history.count) history \(record.history.count == 1 ? "line" : "lines")"
    }

    func copyRows(_ rows: [HostRecord]) {
        guard !rows.isEmpty else { return }
        putOnClipboard(Exporter.clipboard(
            records: rows,
            columns: settings.columns,
            options: ExportOptions.from(settings, columns: settings.columns)
        ))
        status = "Copied \(rows.count) \(rows.count == 1 ? "row" : "rows")"
    }

    func copyLines(_ lines: [String], singular: String, plural: String) {
        let cleaned = lines.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !cleaned.isEmpty else { return }
        putOnClipboard(cleaned.joined(separator: "\n"))
        status = "Copied \(cleaned.count) \(cleaned.count == 1 ? singular : plural)"
    }

    private func putOnClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func copyText(_ text: String, confirmation: String) {
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        status = confirmation
    }

    func pingInTerminal(_ rows: [HostRecord]) {
        let limited = Array(rows.prefix(8))
        for record in limited {
            let host = record.ipText.isEmpty ? record.target.host : record.ipText
            let quoted = CommandTemplate.shellQuote(host)
            let script: String
            if let port = record.target.port {
                script = "nc -vz \(quoted) \(port)"
            } else if HostParser.isIPv6Literal(host) {
                script = "ping6 \(quoted)"
            } else {
                script = "ping \(quoted)"
            }
            do {
                try CommandRunner.openInTerminal(script)
            } catch {
                status = "Could not open Terminal: \(error.localizedDescription)"
                return
            }
        }
        if rows.count > limited.count {
            status = "Opened Terminal for the first \(limited.count) hosts"
        }
    }

    func runCustom(_ item: CustomMenuItem, rows: [HostRecord]) {
        guard !item.isSeparator else { return }
        for record in rows {
            CommandRunner.run(CommandTemplate.render(item.command, record: record, format: settings.displayFormat))
        }
    }

    func reloadCustomMenu() {
        guard let text = try? String(contentsOf: SupportPaths.customMenu, encoding: .utf8) else {
            customMenu = []
            return
        }
        customMenu = CustomMenuFile.parse(text)
    }

    func showMainWindow() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue.contains("main") == true || $0.canBecomeMain }) {
            window.makeKeyAndOrderFront(nil)
            return
        }
        openMainWindow?()
    }

    func openHelp() {
        showMainWindow()
        showHelp = true
    }

    func hideWindows() {
        NSApp.setActivationPolicy(.accessory)
        for window in NSApp.windows where window.canBecomeMain {
            window.orderOut(nil)
        }
    }

    func openWebsite() {
        NSWorkspace.shared.open(Brand.websiteURL)
    }

    func openEmail() {
        NSWorkspace.shared.open(Brand.mailtoURL)
    }

    func revealCustomMenu() {
        let url = SupportPaths.customMenu
        if !FileManager.default.fileExists(atPath: url.path) {
            let sample = """
            [CustomMenu]
            Caption0=Open in Browser
            Command0=open http://%IPAddress%
            Caption1=Copy IP Address
            Command1=printf %s %IPAddress% | pbcopy
            Caption2=-
            Caption3=Say Host Name
            Command3=say %HostName%
            """
            try? sample.write(to: url, atomically: true, encoding: .utf8)
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
        reloadCustomMenu()
    }

    private func run(generation token: UUID) async {
        while token == generation && !Task.isCancelled {
            let began = ContinuousClock.now
            roundIndex += 1
            let enabled = records.filter(\.enabled).count
            status = "Round \(roundIndex): pinging \(enabled) \(enabled == 1 ? "host" : "hosts")"
            let snapshot = records
            let activeSettings = settings
            let results = await ProbeBatch.ping(snapshot, settings: activeSettings)
            if token != generation || Task.isCancelled { break }
            applyResults(results, settings: activeSettings)
            let elapsed = ContinuousClock.now - began
            lastRoundSeconds = seconds(elapsed)
            maybeAutoExport()
            if !settings.pingEvery {
                running = false
                updateActivity()
                status = "Finished · \(upCount) up · \(downCount) down"
                syncStatusItem()
                return
            }
            let wait = Duration.seconds(settings.intervalSeconds) - elapsed
            if wait > .zero {
                do {
                    try await Task.sleep(for: wait)
                } catch {
                    break
                }
            }
        }
        if token == generation {
            running = false
            updateActivity()
            status = "Stopped"
            syncStatusItem()
        }
    }

    private func applyResults(_ results: [PingSampleResult], settings activeSettings: AppSettings) {
        var position: [UUID: Int] = [:]
        position.reserveCapacity(records.count)
        for (index, record) in records.enumerated() {
            position[record.id] = index
        }
        var beep = false
        var logEntries: [(HostRecord, PingSample)] = []
        var blocked = false
        for result in results where !result.sample.skipped {
            blocked = blocked || result.sample.blockedLocally
            guard let index = position[result.id] else { continue }
            let effect = records[index].ingest(result.sample, settings: activeSettings)
            beep = beep || effect.beepFailure || effect.beepRecovery
            if effect.runFailureCommand {
                CommandRunner.run(CommandTemplate.render(activeSettings.failureCommand, record: records[index], format: activeSettings.displayFormat))
            }
            if effect.runRecoveryCommand {
                CommandRunner.run(CommandTemplate.render(activeSettings.successCommand, record: records[index], format: activeSettings.displayFormat))
            }
            if shouldLog(result.sample, mode: activeSettings.logMode) {
                logEntries.append((records[index], result.sample))
            }
            scheduleReverseLookup(index: index)
        }
        trimHistory()
        writeLog(logEntries, settings: activeSettings)
        if beep { playAlert() }
        if localNetworkBlocked != blocked { localNetworkBlocked = blocked }
        status = "Round \(roundIndex) · \(upCount) up · \(downCount) down"
        syncStatusItem()
    }

    private func scheduleReverseLookup(index: Int) {
        guard settings.resolveAddresses, !records[index].didReverseLookup else { return }
        let host = records[index].target.host
        guard HostParser.isIPAddress(host) else { return }
        records[index].didReverseLookup = true
        let id = records[index].id
        ReverseResolver.shared.resolve(host, findLocalNames: settings.findLocalNames) { name in
            Task { @MainActor in
                AppModel.shared.applyReverse(id: id, name: name)
            }
        }
    }

    private func applyReverse(id: UUID, name: String?) {
        guard settings.resolveAddresses, let index = records.firstIndex(where: { $0.id == id }) else { return }
        records[index].reverseName = name
    }

    private func shouldLog(_ sample: PingSample, mode: LogMode) -> Bool {
        switch mode {
        case .off: false
        case .all: true
        case .failedOnly: !sample.success
        }
    }

    private func writeLog(_ entries: [(HostRecord, PingSample)], settings activeSettings: AppSettings) {
        let path = activeSettings.logPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !entries.isEmpty, !path.isEmpty else { return }
        do {
            try LogWriter.append(
                entries: entries,
                path: path,
                includeHeader: activeSettings.includeExportHeader,
                format: activeSettings.displayFormat
            )
            reportedLogError = false
        } catch {
            if !reportedLogError {
                reportedLogError = true
                status = "Log file: \(error.localizedDescription)"
            }
        }
    }

    private func maybeAutoExport() {
        guard settings.autoExportEnabled else { return }
        let path = settings.autoExportPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return }
        if let lastAutoExport, Date().timeIntervalSince(lastAutoExport) < Double(settings.autoExportSeconds) {
            return
        }
        do {
            try Exporter.write(records: sorted(records), format: settings.autoExportFormat, to: path, options: ExportOptions.from(settings))
            lastAutoExport = Date()
        } catch {
            status = "Auto export failed: \(error.localizedDescription)"
        }
    }

    private func trimHistory() {
        guard !records.isEmpty else { return }
        let perHost = max(10, settings.historyLimit / records.count)
        for index in records.indices where records[index].history.count > perHost {
            records[index].history.removeFirst(records[index].history.count - perHost)
        }
    }

    private func playAlert() {
        let now = Date()
        guard now.timeIntervalSince(lastBeep) > 0.8 else { return }
        lastBeep = now
        SoundPlayer.play(settings.soundName)
    }

    private func updateActivity() {
        if running && activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiatedAllowingIdleSystemSleep],
                reason: "Pinging hosts"
            )
        } else if !running, let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
    }

    private func syncStatusItem() {
        if settings.menuBarIcon {
            statusItem.update(down: downCount, running: running, summary: summary)
        } else {
            statusItem.remove()
            if NSApp.activationPolicy() == .accessory {
                NSApp.setActivationPolicy(.regular)
            }
        }
    }

    private func saveSettings() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(settings) else { return }
        try? data.write(to: SupportPaths.settings, options: .atomic)
    }

    private func seconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}

enum SoundPlayer {
    @MainActor
    static func play(_ name: String) {
        if name == "System" || name.isEmpty {
            NSSound.beep()
            return
        }
        if let sound = NSSound(named: NSSound.Name(name)) {
            sound.play()
        } else {
            NSSound.beep()
        }
    }
}

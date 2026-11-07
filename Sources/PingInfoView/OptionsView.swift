import AppKit
import Combine
import SwiftUI

final class OptionsSession: ObservableObject {
    @Published var draft = AppSettings()
    @Published var warnings: [String] = []
    @Published var previewCount = 0
}

struct OptionsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var session = OptionsSession()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Ping Options")
                        .font(.title2.weight(.semibold))
                    Text("\(session.previewCount) \(session.previewCount == 1 ? "host" : "hosts")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Apply") { apply(start: false) }
                    .disabled(session.previewCount == 0 && model.records.isEmpty)
                Button(startButtonTitle) { apply(start: true) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(session.previewCount == 0)
            }
            .padding(16)

            TabView {
                hostsTab.tabItem { Label("Hosts", systemImage: "list.bullet") }
                pingTab.tabItem { Label("Ping", systemImage: "timer") }
                alertsTab.tabItem { Label("Alerts", systemImage: "bell") }
                exportTab.tabItem { Label("Export", systemImage: "square.and.arrow.up") }
                displayTab.tabItem { Label("Display", systemImage: "eye") }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
        }
        .frame(minWidth: 560, idealWidth: 740, maxWidth: 1000, minHeight: 460, idealHeight: 620, maxHeight: 900)
        .onAppear {
            session.draft = model.settings
            refreshPreview()
        }
        .onReceive(session.$draft.removeDuplicates { $0.hostList == $1.hostList && $0.parseOptions == $1.parseOptions }) { draft in
            refreshPreview(draft)
        }
    }

    private var hostsTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker("Format", selection: $session.draft.hostListFormat) {
                    ForEach(HostListFormat.allCases) { format in
                        Text(format.title).tag(format)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 260)
                Spacer(minLength: 8)
                Button("Insert Example") {
                    if !session.draft.hostList.isEmpty { session.draft.hostList += "\n" }
                    session.draft.hostList += ExampleHosts.text
                    session.draft.hostListFormat = .described
                }
                Button("Load File…") { loadFile() }
            }
            Text("One host per line, or several separated by spaces or commas. Use address:port for a TCP check. In IP and description mode, put the description after the address. Lines starting with # are ignored. Start a section with Group: Name.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $session.draft.hostList)
                .font(.system(.body, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(Color(nsColor: .textBackgroundColor))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.25)))
            if !session.warnings.isEmpty {
                Text(session.warnings.joined(separator: "\n"))
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(4)
            }
            TextField("Window title", text: $session.draft.windowTitle)
                .textFieldStyle(.roundedBorder)
            Toggle("Start pinging immediately the next time PingInfoView opens", isOn: $session.draft.startImmediately)
            Toggle("Put an icon in the menu bar", isOn: $session.draft.menuBarIcon)
            Toggle("Start hidden", isOn: $session.draft.startHidden)
                .disabled(!session.draft.menuBarIcon)
        }
        .padding(8)
    }

    private var pingTab: some View {
        Form {
            Toggle("Repeat", isOn: $session.draft.pingEvery)
            Toggle("Clear existing results once when a scan starts", isOn: $session.draft.clearResultsOnStart)
            Text("Succeeded, failed, and history go back to zero before the first round. Later rounds in the same scan keep the new counts. New Scan always clears once.")
                .font(.caption)
                .foregroundStyle(.secondary)
            LabeledContent("Interval") { number($session.draft.intervalSeconds, 1...86_400, "seconds") }
            LabeledContent("Timeout") { number($session.draft.timeoutMs, 100...120_000, "ms") }
            LabeledContent("Packet size") { number($session.draft.payloadSize, 0...65_507, "bytes") }
            LabeledContent("Concurrent pings") { number($session.draft.maxConcurrent, 1...500, "") }
            LabeledContent("Time to live") { number($session.draft.ttl, 0...255, "0 uses the system default") }
            Toggle("Don't fragment IPv4 packets", isOn: $session.draft.dontFragment)
            TextField("Source address", text: $session.draft.sourceAddress)
            Toggle("Allow IPv6 and try IPv6 first for names", isOn: $session.draft.allowIPv6)
            Toggle("Resolve IP addresses to host names", isOn: $session.draft.resolveAddresses)
            Toggle("Resolve names again on every ping", isOn: $session.draft.resolveEveryPing)
            Toggle("Skip the network address in a CIDR range", isOn: $session.draft.skipFirstInCIDR)
            Toggle("Skip the broadcast address in a CIDR range", isOn: $session.draft.skipLastInCIDR)
            LabeledContent("Expansion limit") { number($session.draft.expansionLimit, 1...65_536, "addresses") }
        }
        .formStyle(.grouped)
    }

    private var alertsTab: some View {
        Form {
            Toggle("Beep on failed pings", isOn: $session.draft.beepOnFailed)
            Toggle("Beep when a host recovers", isOn: $session.draft.beepOnSuccessAfterFailure)
            Picker("Sound", selection: $session.draft.soundName) {
                ForEach(SoundCatalog.names, id: \.self) { Text($0).tag($0) }
            }
            Button("Play Sound") { SoundPlayer.play(session.draft.soundName) }
            LabeledContent("Failures before an alert") { number($session.draft.alertAfterConsecutive, 1...10_000, "") }
            TextField("Command after a failure streak", text: $session.draft.failureCommand)
            TextField("Command when the host recovers", text: $session.draft.successCommand)
            Text("Values are inserted as quoted arguments. Example: say Host %HostName% is down")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(CommandTemplate.tokens.map(\.token).joined(separator: "  "))
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .formStyle(.grouped)
    }

    private var exportTab: some View {
        Form {
            Picker("History", selection: $session.draft.lowerPaneMode) {
                ForEach(LowerPaneMode.allCases) { Text($0.title).tag($0) }
            }
            LabeledContent("Remember") { number($session.draft.historyLimit, 10...200_000, "ping lines") }
            Toggle("Auto export", isOn: $session.draft.autoExportEnabled)
            LabeledContent("Export every") { number($session.draft.autoExportSeconds, 1...86_400, "seconds") }
            Picker("Auto export format", selection: $session.draft.autoExportFormat) {
                ForEach(ExportFormat.allCases) { Text($0.title).tag($0) }
            }
            TextField("Auto export path", text: $session.draft.autoExportPath)
            Text("Use {date} and {time} in the path for a new file. Example: ~/Desktop/ping-{date}-{time}.csv")
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker("Log", selection: $session.draft.logMode) {
                ForEach(LogMode.allCases) { Text($0.title).tag($0) }
            }
            TextField("Log path", text: $session.draft.logPath)
            Toggle("Include a header row", isOn: $session.draft.includeExportHeader)
        }
        .formStyle(.grouped)
    }

    private var displayTab: some View {
        Form {
            Section {
                Toggle("Show the history pane", isOn: $session.draft.showLowerPane)
                Toggle("Scroll history to the latest ping", isOn: $session.draft.autoScrollLowerPane)
                Toggle("Sort again after every round", isOn: $session.draft.sortOnEveryUpdate)
                Toggle("Always on top", isOn: $session.draft.alwaysOnTop)
                Toggle("High resolution ping times", isOn: $session.draft.highResolutionTime)
                Toggle("Show times in GMT", isOn: $session.draft.useGMT)
                Toggle("Alternate row shading", isOn: $session.draft.alternateRows)
                Toggle("Black background", isOn: $session.draft.blackBackground)
                Toggle("Hide disabled hosts", isOn: $session.draft.hideDisabled)
                Picker("Display", selection: $session.draft.displayMode) {
                    ForEach(DisplayMode.allCases) { Text($0.title).tag($0) }
                }
                LabeledContent("Font size") {
                    HStack {
                        Slider(value: $session.draft.fontSize, in: 10...22, step: 1)
                            .frame(minWidth: 120)
                        Text("\(Int(session.draft.fontSize))").monospacedDigit().frame(width: 28)
                    }
                }
            }
            Section {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), alignment: .leading)], alignment: .leading, spacing: 6) {
                    ForEach(ColumnID.allCases) { column in
                        Toggle(column.title, isOn: columnBinding(column))
                    }
                }
            } header: {
                Text("Columns")
            } footer: {
                Text("Columns that don't fit the window are hidden automatically, starting with the least important. Exports always include every checked column.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                Button("Edit Custom Menu…") { model.revealCustomMenu() }
                Text(SupportPaths.customMenu.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            } header: {
                Text("Custom menu")
            }
        }
        .formStyle(.grouped)
    }

    private func number(_ value: Binding<Int>, _ range: ClosedRange<Int>, _ suffix: String) -> some View {
        let text = Binding<String>(
            get: { String(value.wrappedValue) },
            set: { typed in
                let digits = typed.filter(\.isNumber)
                if let number = Int(digits) {
                    value.wrappedValue = number
                }
            }
        )
        return HStack {
            TextField("", text: text)
                .frame(width: 80)
                .multilineTextAlignment(.trailing)
                .help("\(range.lowerBound)–\(range.upperBound)")
            Stepper("", value: value, in: range)
                .labelsHidden()
            if !suffix.isEmpty {
                Text(suffix).foregroundStyle(.secondary)
            }
        }
    }

    private func columnBinding(_ column: ColumnID) -> Binding<Bool> {
        Binding(
            get: { session.draft.visibleColumns.contains(column.rawValue) },
            set: { isOn in
                if isOn {
                    if !session.draft.visibleColumns.contains(column.rawValue) {
                        session.draft.visibleColumns.append(column.rawValue)
                    }
                } else {
                    session.draft.visibleColumns.removeAll { $0 == column.rawValue }
                }
            }
        )
    }

    private func refreshPreview(_ draft: AppSettings? = nil) {
        let source = draft ?? session.draft
        let parsed = HostParser.parse(source.hostList, options: source.normalized().parseOptions)
        session.previewCount = parsed.targets.count
        session.warnings = parsed.warnings
    }

    private var startButtonTitle: String {
        if session.draft.clearResultsOnStart {
            return model.running ? "Clear and Restart" : "New Scan"
        }
        return model.running ? "Save and Restart" : "Start Pinging"
    }

    private func apply(start: Bool) {
        var next = session.draft.normalized()
        next.didConfigure = true
        session.draft = next
        if start {
            model.applyAndStart(next)
        } else {
            model.applyKeepingStats(next)
        }
        dismiss()
    }

    private func loadFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Load"
        if panel.runModal() == .OK, let url = panel.url, let text = try? TextFile.read(url) {
            if !session.draft.hostList.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                session.draft.hostList += "\n"
            }
            session.draft.hostList += text
        }
    }
}

enum ExampleHosts {
    static let text = """
    Group: DNS
    1.1.1.1 Cloudflare DNS
    8.8.8.8 Google DNS

    Group: Local
    127.0.0.1 This Mac

    Group: Web
    example.com:443 Example website
    """
}

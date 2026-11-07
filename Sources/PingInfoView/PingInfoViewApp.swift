import AppKit
import Darwin
import SwiftUI

@main
enum EntryPoint {
    static func main() {
        raiseFileLimit()
        let arguments = Array(CommandLine.arguments.dropFirst())
        let options = LaunchOptions.parse(arguments)
        if options.requestsHeadless {
            exit(LaunchOptions.headless(options))
        }
        LaunchBridge.options = options
        PingInfoViewApp.main()
    }

    /// Apps launched from Finder start with a 256 file-descriptor limit; each concurrent ping needs a pipe.
    private static func raiseFileLimit() {
        var limit = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &limit) == 0 else { return }
        let target = min(limit.rlim_max, rlim_t(8192))
        if limit.rlim_cur < target {
            limit.rlim_cur = target
            setrlimit(RLIMIT_NOFILE, &limit)
        }
    }
}

struct PingInfoViewApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        Window(Brand.appName, id: "main") {
            ContentView()
                .environmentObject(model)
        }
        .defaultSize(width: 1100, height: 720)
        .commands {
            AppCommands(model: model)
        }
    }
}

struct AppCommands: Commands {
    @ObservedObject var model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About \(Brand.appName)") { AboutPanel.show() }
        }
        CommandGroup(replacing: .appSettings) {
            Button("Ping Options…") {
                model.showMainWindow()
                model.showOptions = true
            }
            .keyboardShortcut(",", modifiers: .command)
        }
        CommandGroup(replacing: .newItem) {
            Button("Load Addresses…") { model.loadHostFile() }
                .keyboardShortcut("o", modifiers: .command)
            Menu("Export") {
                ForEach(ExportFormat.allCases) { format in
                    Button(format.title) { model.export(format) }
                }
            }
            .disabled(model.records.isEmpty)
        }
        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Copy Rows") { model.copySelectionOrVisible() }
                .disabled(model.records.isEmpty)
            Button("Copy Host Names") { model.copyHostNames() }
                .disabled(model.records.isEmpty)
            Button("Copy IP Addresses") { model.copyAddresses() }
                .disabled(model.records.isEmpty)
            Divider()
            Button("Select All Hosts") { model.selectAll() }
                .disabled(model.records.isEmpty)
            Button("Deselect") { model.clearSelection() }
                .disabled(model.selection.isEmpty)
        }
        CommandMenu("Monitor") {
            Button("Rescan") { model.start() }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(model.running || model.records.isEmpty)
            Button("New Scan") { model.newScan() }
                .keyboardShortcut("r", modifiers: [.command, .option])
                .disabled(model.records.isEmpty)
            Button("Stop") { model.stop() }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(!model.running)
            Button("Reset Counters") { model.resetCounters() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(model.records.isEmpty)
            Divider()
            Button("Enable Selected") { model.setEnabled(true, ids: model.selection) }
                .disabled(model.selection.isEmpty)
            Button("Disable Selected") { model.setEnabled(false, ids: model.selection) }
                .disabled(model.selection.isEmpty)
        }
        CommandGroup(after: .toolbar) {
            Divider()
            Picker("Display", selection: binding(\.displayMode)) {
                ForEach(DisplayMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            Toggle("Show History Pane", isOn: binding(\.showLowerPane))
            Toggle("Always on Top", isOn: binding(\.alwaysOnTop))
            Toggle("Menu Bar Icon", isOn: binding(\.menuBarIcon))
            Toggle("Sort on Every Update", isOn: binding(\.sortOnEveryUpdate))
            Toggle("High Resolution Times", isOn: binding(\.highResolutionTime))
            Toggle("Alternate Rows", isOn: binding(\.alternateRows))
            Toggle("Black Background", isOn: binding(\.blackBackground))
            Toggle("Hide Disabled Hosts", isOn: binding(\.hideDisabled))
            Toggle("Beep on Failed Pings", isOn: binding(\.beepOnFailed))
            Divider()
        }
        CommandGroup(replacing: .help) {
            Button("\(Brand.appName) Help") { model.openHelp() }
            Divider()
            Button("Visit \(Brand.website)") { model.openWebsite() }
            Button("Email \(Brand.email)") { model.openEmail() }
        }
    }

    private func binding<Value: Equatable>(_ keyPath: WritableKeyPath<AppSettings, Value>) -> Binding<Value> {
        Binding(
            get: { model.settings[keyPath: keyPath] },
            set: { model.update(keyPath, to: $0) }
        )
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        let settings = AppModel.shared.settings
        let hasHosts = !settings.hostList.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if settings.menuBarIcon && settings.startHidden && settings.startImmediately && hasHosts {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppModel.shared.launch()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !AppModel.shared.settings.menuBarIcon
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            AppModel.shared.showMainWindow()
        }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        AppModel.shared.stop()
        return .terminateNow
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        let model = AppModel.shared
        let replace = model.settings.hostList.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        model.importHostFile(url, replace: replace)
    }
}

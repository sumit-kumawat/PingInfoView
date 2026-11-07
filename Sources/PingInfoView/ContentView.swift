import AppKit
import SwiftUI
import UniformTypeIdentifiers

final class DropState: ObservableObject {
    @Published var targeted = false
}

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @StateObject private var drop = DropState()

    var body: some View {
        VStack(spacing: 0) {
            summaryBar
            Divider()
            if !model.warnings.isEmpty {
                warningBar
                Divider()
            }
            if model.settings.showLowerPane {
                VSplitView {
                    HostTable()
                        .frame(minHeight: 150, maxHeight: .infinity)
                    HistoryPane()
                        .frame(minHeight: 110, idealHeight: 200, maxHeight: .infinity)
                }
            } else {
                HostTable()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            statusBar
        }
        .frame(minWidth: 560, idealWidth: 1100, minHeight: 380, idealHeight: 720)
        .background(WindowChrome(
            title: model.effectiveTitle,
            level: model.settings.alwaysOnTop ? .floating : .normal
        ))
        .background(OpenWindowBinder(open: { openWindow(id: "main") }))
        .toolbar { toolbar }
        .searchable(text: $model.query, placement: .toolbar, prompt: "Filter hosts")
        .sheet(isPresented: $model.showOptions) {
            OptionsView().environmentObject(model)
        }
        .sheet(isPresented: $model.showHelp) { HelpView() }
        .onDrop(of: [UTType.fileURL], isTargeted: $drop.targeted, perform: handleDrop)
        .overlay {
            if drop.targeted {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
    }

    private var summaryBar: some View {
        HStack(spacing: 14) {
            Button { AboutPanel.show() } label: {
                HStack(spacing: 8) {
                    AppIcon(side: 28)
                    Text(Brand.appName)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }
            }
            .buttonStyle(.plain)
            .help("\(Brand.appName) \(Brand.version) by \(Brand.creditLine)")
            count("Hosts", model.records.count, .secondary)
            count("Up", model.upCount, .green)
            count("Down", model.downCount, .red)
            if model.disabledCount > 0 {
                count("Off", model.disabledCount, .gray)
            }
            if model.running {
                Label("Live", systemImage: "circle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.green)
            }
            Spacer(minLength: 8)
            ViewThatFits(in: .horizontal) {
                Text(model.status).lineLimit(1)
                EmptyView()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func count(_ title: String, _ value: Int, _ color: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(title).foregroundStyle(.secondary)
            Text("\(value)").font(.body.monospacedDigit().weight(.semibold))
        }
        .font(.callout)
        .fixedSize()
    }

    private var warningBar: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(model.warnings.joined(separator: " "))
                .font(.callout)
                .lineLimit(2)
                .help(model.warnings.joined(separator: "\n"))
            Spacer(minLength: 4)
            Button("Dismiss") { model.warnings = [] }
                .buttonStyle(.borderless)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.orange.opacity(0.12))
    }

    private var statusBar: some View {
        HStack(spacing: 10) {
            Text(model.summary)
                .lineLimit(1)
                .truncationMode(.tail)
            if let record = singleSelection, let error = record.lastError, record.lastStatus == .down {
                Text(error).foregroundStyle(.red).lineLimit(1)
            }
            Spacer(minLength: 8)
            Button { AboutPanel.show() } label: {
                ViewThatFits(in: .horizontal) {
                    Text(Brand.creditLine)
                    Text(Brand.author)
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("\(Brand.appName) \(Brand.version) by \(Brand.creditLine)")
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(.bar)
    }

    private var singleSelection: HostRecord? {
        guard model.selection.count == 1, let id = model.selection.first else { return nil }
        return model.records.first { $0.id == id }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button { model.start() } label: { Label("Start", systemImage: "play.fill") }
                .help(model.settings.clearResultsOnStart ? "Start a scan and clear the current results once (⌘R)" : "Start pinging (⌘R)")
                .disabled(model.running || model.records.isEmpty)
            Button { model.newScan() } label: { Label("New Scan", systemImage: "arrow.triangle.2.circlepath") }
                .help("Clear the current results once, then start (⌥⌘R)")
                .disabled(model.records.isEmpty)
            Button { model.stop() } label: { Label("Stop", systemImage: "stop.fill") }
                .help("Stop (⌘.)")
                .disabled(!model.running)
            Button { model.resetCounters() } label: { Label("Reset", systemImage: "arrow.counterclockwise") }
                .help("Reset counters")
                .disabled(model.records.isEmpty)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Menu {
                Picker("Show", selection: displayMode) {
                    ForEach(DisplayMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.inline)
                if !model.groupNames.isEmpty {
                    Picker("Group", selection: $model.groupFilter) {
                        Text("All groups").tag("All")
                        ForEach(model.groupNames, id: \.self) { name in
                            Text(name).tag(name)
                        }
                    }
                    .pickerStyle(.inline)
                }
            } label: {
                Label("Show", systemImage: filterActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
            }
            .help("Choose which hosts to show")
            Button { model.showOptions = true } label: { Label("Options", systemImage: "slider.horizontal.3") }
                .help("Ping options (⌘,)")
            Menu {
                ForEach(ExportFormat.allCases) { format in
                    Button(format.title) { model.export(format) }
                }
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .help("Export the selected rows, or every visible row")
            .disabled(model.records.isEmpty)
            Button { model.copySelectionOrVisible() } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            .help("Copy the selected rows, or every visible row (⌘C)")
            .disabled(model.records.isEmpty)
        }
    }

    private var filterActive: Bool {
        model.settings.displayMode != .all || model.groupFilter != "All"
    }

    private var displayMode: Binding<DisplayMode> {
        Binding(
            get: { model.settings.displayMode },
            set: { model.update(\.displayMode, to: $0) }
        )
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let files = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !files.isEmpty else { return false }
        for provider in files {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                let url: URL?
                if let direct = item as? URL {
                    url = direct
                } else if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else {
                    url = nil
                }
                guard let url else { return }
                Task { @MainActor in
                    AppModel.shared.importHostFile(url, replace: false)
                }
            }
        }
        return true
    }
}

struct AppIcon: View {
    var side: CGFloat

    var body: some View {
        Image(nsImage: Brand.icon)
            .resizable()
            .renderingMode(.original)
            .interpolation(.high)
            .frame(width: side, height: side)
            .accessibilityLabel(Brand.appName)
    }
}

struct WindowChrome: NSViewRepresentable {
    var title: String
    var level: NSWindow.Level

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let window = nsView.window else { return }
            if window.title != title { window.title = title }
            if window.level != level { window.level = level }
            window.collectionBehavior.insert(.fullScreenPrimary)
            context.coordinator.installIcon(on: window)
        }
    }

    @MainActor
    final class Coordinator: NSObject {
        private let accessoryID = NSUserInterfaceItemIdentifier("pinginfoview-title-icon")

        @objc func showAbout() { AboutPanel.show() }

        func installIcon(on window: NSWindow) {
            guard !window.titlebarAccessoryViewControllers.contains(where: { $0.identifier == accessoryID }) else { return }
            let button = NSButton(image: Brand.icon(side: 20), target: self, action: #selector(showAbout))
            button.isBordered = false
            button.imageScaling = .scaleProportionallyUpOrDown
            button.imagePosition = .imageOnly
            button.toolTip = "\(Brand.appName) \(Brand.version)"
            button.setAccessibilityLabel(Brand.appName)
            button.translatesAutoresizingMaskIntoConstraints = false
            let container = NSView()
            container.addSubview(button)
            NSLayoutConstraint.activate([
                button.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 4),
                button.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                button.centerYAnchor.constraint(equalTo: container.centerYAnchor),
                button.widthAnchor.constraint(equalToConstant: 20),
                button.heightAnchor.constraint(equalToConstant: 20),
                container.widthAnchor.constraint(equalToConstant: 28),
                container.heightAnchor.constraint(equalToConstant: 28)
            ])
            let accessory = NSTitlebarAccessoryViewController()
            accessory.identifier = accessoryID
            accessory.layoutAttribute = .leading
            accessory.view = container
            window.addTitlebarAccessoryViewController(accessory)
        }
    }
}

private struct OpenWindowBinder: View {
    var open: () -> Void

    var body: some View {
        Color.clear.frame(width: 0, height: 0)
            .onAppear { AppModel.shared.openMainWindow = open }
    }
}

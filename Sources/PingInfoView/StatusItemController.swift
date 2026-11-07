import AppKit

@MainActor
final class StatusItemController: NSObject {
    var onShow: () -> Void = {}
    var onStart: () -> Void = {}
    var onNewScan: () -> Void = {}
    var onStop: () -> Void = {}
    var onAbout: () -> Void = {}

    private var item: NSStatusItem?
    private var down = 0
    private var running = false
    private var summary = ""

    func update(down: Int, running: Bool, summary: String) {
        self.down = down
        self.running = running
        self.summary = summary
        if item == nil {
            let created = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            created.button?.image = Brand.icon(side: 18)
            created.menu = NSMenu()
            item = created
        }
        item?.button?.title = down > 0 ? " \(down)" : ""
        rebuildMenu()
    }

    func remove() {
        guard let item else { return }
        NSStatusBar.system.removeStatusItem(item)
        self.item = nil
    }

    private func rebuildMenu() {
        guard let menu = item?.menu else { return }
        menu.removeAllItems()
        let title = NSMenuItem(title: Brand.appName, action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        if !summary.isEmpty {
            let detail = NSMenuItem(title: summary, action: nil, keyEquivalent: "")
            detail.isEnabled = false
            menu.addItem(detail)
        }
        menu.addItem(.separator())
        add("Show \(Brand.appName)", action: #selector(showWindow), enabled: true)
        add("Rescan", action: #selector(startPinging), enabled: !running)
        add("New Scan", action: #selector(startNewScan), enabled: true)
        add("Stop", action: #selector(stopPinging), enabled: running)
        menu.addItem(.separator())
        add("About \(Brand.appName)", action: #selector(showAbout), enabled: true)
        add("Quit", action: #selector(quit), enabled: true, key: "q")
    }

    private func add(_ title: String, action: Selector, enabled: Bool, key: String = "") {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        item.isEnabled = enabled
        menuItem()?.addItem(item)
    }

    private func menuItem() -> NSMenu? { item?.menu }

    @objc private func showWindow() { onShow() }
    @objc private func startPinging() { onStart() }
    @objc private func startNewScan() { onNewScan() }
    @objc private func stopPinging() { onStop() }
    @objc private func showAbout() { onAbout() }
    @objc private func quit() { NSApp.terminate(nil) }
}

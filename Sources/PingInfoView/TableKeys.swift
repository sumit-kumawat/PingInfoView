import AppKit
import SwiftUI

/// Key handling for the host table. Shortcuts apply in the main window and stay out of text fields and sheets,
/// so the search field and Ping Options keep their own Copy and Select All.
struct TableKeys: NSViewRepresentable {
    var pageRows: Int

    func makeNSView(context: Context) -> TableKeyView {
        let view = TableKeyView()
        view.pageRows = max(1, pageRows)
        return view
    }

    func updateNSView(_ view: TableKeyView, context: Context) {
        view.pageRows = max(1, pageRows)
    }
}

final class TableKeyView: NSView {
    var pageRows = 8
    private var monitor: Any?
    private var keyObserver: NSObjectProtocol?
    private var menuObservers: [NSObjectProtocol] = []
    private var menuTracking = 0

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        removeHooks()
        guard let window else { return }
        let watched = window
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === watched else { return event }
            return self.handle(event) ? nil : event
        }
        keyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.grabFocusIfIdle()
            }
        }
        menuObservers = [NSMenu.didBeginTrackingNotification, NSMenu.didEndTrackingNotification].map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if name == NSMenu.didBeginTrackingNotification {
                        self.menuTracking += 1
                    } else {
                        self.menuTracking = max(0, self.menuTracking - 1)
                    }
                }
            }
        }
        grabFocusIfIdle()
        AppModel.shared.focusTable = { [weak self] in
            self?.window?.makeFirstResponder(self)
        }
    }

    deinit {
        MainActor.assumeIsolated {
            removeHooks()
        }
    }

    private func removeHooks() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        if let keyObserver {
            NotificationCenter.default.removeObserver(keyObserver)
            self.keyObserver = nil
        }
        for observer in menuObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        menuObservers = []
        menuTracking = 0
    }

    @objc func copy(_ sender: Any?) {
        Task { @MainActor in AppModel.shared.copySelectionOrVisible() }
    }

    @objc override func selectAll(_ sender: Any?) {
        Task { @MainActor in AppModel.shared.selectAll() }
    }

    override func responds(to selector: Selector!) -> Bool {
        if selector == #selector(copy(_:)) || selector == #selector(selectAll(_:)) { return true }
        return super.responds(to: selector)
    }

    private func grabFocusIfIdle() {
        guard let window, window.isKeyWindow, window.attachedSheet == nil else { return }
        let responder = window.firstResponder
        if responder == nil || responder === window {
            window.makeFirstResponder(self)
        }
    }

    private func handle(_ event: NSEvent) -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        return MainActor.assumeIsolated { handleOnMain(event) }
    }

    @MainActor
    private func handleOnMain(_ event: NSEvent) -> Bool {
        guard let window = self.window, window.isKeyWindow, window.attachedSheet == nil else { return false }
        if NSApp.modalWindow != nil || menuTracking > 0 { return false }
        if Self.isEditingText(window.firstResponder) { return false }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let command = flags.contains(.command)
        let shift = flags.contains(.shift)
        let option = flags.contains(.option)
        let control = flags.contains(.control)
        let model = AppModel.shared

        switch event.specialKey {
        case .upArrow:
            if command { model.jumpSelection(toEnd: false, extending: shift) }
            else { model.moveSelection(by: -1, extending: shift) }
            return true
        case .downArrow:
            if command { model.jumpSelection(toEnd: true, extending: shift) }
            else { model.moveSelection(by: 1, extending: shift) }
            return true
        case .pageUp:
            model.moveSelection(by: -pageRows, extending: shift)
            return true
        case .pageDown:
            model.moveSelection(by: pageRows, extending: shift)
            return true
        case .home:
            model.jumpSelection(toEnd: false, extending: shift)
            return true
        case .end:
            model.jumpSelection(toEnd: true, extending: shift)
            return true
        case .leftArrow:
            return model.setLeadGroupCollapsed(true)
        case .rightArrow:
            return model.setLeadGroupCollapsed(false)
        default:
            break
        }

        if event.keyCode == 53 {
            if !model.selection.isEmpty {
                model.clearSelection()
                return true
            }
            if !model.query.isEmpty {
                model.query = ""
                return true
            }
            return false
        }

        let typed = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if command, !option, !control, typed == "c" {
            if shift { model.copyHostNames() }
            else { model.copySelectionOrVisible() }
            return true
        }
        if command, option, !control, !shift, typed == "c" {
            model.copyAddresses()
            return true
        }
        if command, !option, !control, !shift, typed == "a" {
            model.selectAll()
            return true
        }
        if command || option || control || event.isARepeat { return false }
        guard typed.count == 1, let scalar = typed.unicodeScalars.first, Self.isTypeable(scalar) else { return false }
        model.typeSelect(typed)
        return true
    }

    private static func isEditingText(_ responder: NSResponder?) -> Bool {
        if responder is NSTextView { return true }
        if let field = responder as? NSTextField, field.isEditable { return true }
        return false
    }

    private static func isTypeable(_ scalar: Unicode.Scalar) -> Bool {
        CharacterSet.alphanumerics.contains(scalar) || scalar == "." || scalar == ":" || scalar == "-"
    }
}

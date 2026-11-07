import AppKit
import Foundation

enum Brand {
    static let appName = "PingInfoView"
    static let version = "1.3.0"
    static let build = "3"
    static let author = "Sumit Kumawat"
    static let website = "www.sumitkumawat.com"
    static let websiteURL = URL(string: "https://www.sumitkumawat.com")!
    static let email = "hello@sumitkumawat.com"
    static let mailtoURL = URL(string: "mailto:hello@sumitkumawat.com")!
    static let bundleIdentifier = "com.sumitkumawat.pinginfoview"
    static let copyright = "© 2026 Sumit Kumawat"
    static let tagline = "Ping many hosts and watch the results in one table."

    static var creditLine: String {
        "\(author) · \(website) · \(email)"
    }

    /// The same artwork used for the Dock icon, sized for a header or the menu bar.
    @MainActor
    static var icon: NSImage {
        if let icon = NSApp.applicationIconImage, icon.size.width > 1, icon.size.height > 1 {
            return icon
        }
        return NSImage(systemSymbolName: "dot.radiowaves.left.and.right", accessibilityDescription: appName) ?? NSImage()
    }

    @MainActor
    static func icon(side: CGFloat) -> NSImage {
        let copy = icon.copy() as? NSImage ?? icon
        copy.size = NSSize(width: side, height: side)
        copy.isTemplate = false
        return copy
    }
}

@MainActor
enum AboutPanel {
    static func show() {
        NSApp.activate(ignoringOtherApps: true)
        let center = NSMutableParagraphStyle()
        center.alignment = .center
        let body: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: center
        ]
        let credits = NSMutableAttributedString(string: "\(Brand.tagline)\n\nAuthor: \(Brand.author)\n", attributes: body)
        var website = body
        website[.link] = Brand.websiteURL
        credits.append(NSAttributedString(string: Brand.website, attributes: website))
        credits.append(NSAttributedString(string: "\n", attributes: body))
        var email = body
        email[.link] = Brand.mailtoURL
        credits.append(NSAttributedString(string: Brand.email, attributes: email))

        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: Brand.appName,
            .applicationVersion: Brand.version,
            .version: Brand.build,
            .credits: credits,
            NSApplication.AboutPanelOptionKey(rawValue: "Copyright"): Brand.copyright
        ])
    }
}

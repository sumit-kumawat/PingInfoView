import Foundation

enum ExportError: LocalizedError {
    case emptyPath
    case unwritable(String)

    var errorDescription: String? {
        switch self {
        case .emptyPath:
            "Choose a file path before exporting."
        case .unwritable(let message):
            message
        }
    }
}

enum Exporter {
    static func write(records: [HostRecord], format: ExportFormat, to path: String, options: ExportOptions) throws {
        let expanded = PathTokens.expand(path)
        guard !expanded.isEmpty else { throw ExportError.emptyPath }
        let url = URL(fileURLWithPath: expanded)
        let folder = url.deletingLastPathComponent()
        if !folder.path.isEmpty && folder.path != "/" {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let text = render(records: records, format: format, options: options)
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            throw ExportError.unwritable(error.localizedDescription)
        }
    }

    static func render(records: [HostRecord], format: ExportFormat, options: ExportOptions) -> String {
        switch format {
        case .text:
            return aligned(records: records, options: options, rules: false)
        case .tabular:
            return aligned(records: records, options: options, rules: true)
        case .csv:
            return delimited(records: records, separator: ",", options: options)
        case .tab:
            return delimited(records: records, separator: "\t", options: options)
        case .html:
            return html(records: records, options: options, vertical: false)
        case .verticalHTML:
            return html(records: records, options: options, vertical: true)
        case .xml:
            return xml(records: records, options: options)
        }
    }

    static func clipboard(records: [HostRecord], columns: [ColumnID], options: ExportOptions) -> String {
        delimited(records: records, columns: columns, separator: "\t", options: options)
    }

    private static func delimited(records: [HostRecord], separator: String, options: ExportOptions) -> String {
        delimited(records: records, columns: options.columns, separator: separator, options: options)
    }

    private static func delimited(records: [HostRecord], columns: [ColumnID], separator: String, options: ExportOptions) -> String {
        var lines: [String] = []
        if options.includeHeader {
            lines.append(columns.map { field($0.title, separator: separator) }.joined(separator: separator))
        }
        for record in records {
            let cells = columns.map { field(record.text(for: $0, format: options.display), separator: separator) }
            lines.append(cells.joined(separator: separator))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func aligned(records: [HostRecord], options: ExportOptions, rules: Bool) -> String {
        let columns = options.columns
        var widths = columns.map { $0.title.count }
        let rows = records.map { record in
            columns.map { record.text(for: $0, format: options.display) }
        }
        for row in rows {
            for (index, cell) in row.enumerated() {
                widths[index] = max(widths[index], cell.count)
            }
        }
        func paint(_ cells: [String]) -> String {
            let body = zip(cells, widths).map { cell, width in
                cell.count >= width ? cell : cell + String(repeating: " ", count: width - cell.count)
            }.joined(separator: rules ? " | " : "  ")
            return rules ? "| \(body) |" : body
        }
        var lines: [String] = []
        lines.append("\(Brand.appName) \(Brand.version)")
        lines.append(Brand.creditLine)
        lines.append("Generated \(ISO8601DateFormatter().string(from: Date()))")
        lines.append("")
        if options.includeHeader {
            let header = columns.map(\.title)
            lines.append(paint(header))
            if rules {
                let rule = widths.map { String(repeating: "-", count: $0) }
                lines.append(paint(rule).replacingOccurrences(of: " | ", with: "-+-").replacingOccurrences(of: "| ", with: "|-").replacingOccurrences(of: " |", with: "-|"))
            }
        }
        lines.append(contentsOf: rows.map(paint))
        lines.append("")
        return lines.joined(separator: "\n")
    }

    private static func html(records: [HostRecord], options: ExportOptions, vertical: Bool) -> String {
        let columns = options.columns
        var body = ""
        if vertical {
            for record in records {
                body += "<h2>\(escape(record.hostNameText))</h2><table>"
                for column in columns {
                    body += "<tr><th>\(escape(column.title))</th><td>\(escape(record.text(for: column, format: options.display)))</td></tr>"
                }
                body += "</table>"
            }
        } else {
            body += "<table><thead><tr>"
            if options.includeHeader {
                for column in columns {
                    body += "<th>\(escape(column.title))</th>"
                }
            }
            body += "</tr></thead><tbody>"
            for record in records {
                body += "<tr>"
                for column in columns {
                    let value = record.text(for: column, format: options.display)
                    let failed = column == .status && record.lastStatus == .down
                    body += failed ? "<td class=\"failed\">\(escape(value))</td>" : "<td>\(escape(value))</td>"
                }
                body += "</tr>"
            }
            body += "</tbody></table>"
        }
        return """
        <!DOCTYPE html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <title>\(escape(Brand.appName))</title>
        <style>
        body { font-family: -apple-system, BlinkMacSystemFont, sans-serif; margin: 32px; color: #1d1d1f; }
        table { border-collapse: collapse; width: 100%; margin-bottom: 28px; }
        th, td { border: 1px solid #d2d2d7; padding: 6px 8px; text-align: left; font-size: 13px; }
        th { background: #f5f5f7; }
        td.failed { color: #b42318; font-weight: 600; }
        footer { margin-top: 24px; color: #6e6e73; font-size: 12px; }
        </style>
        </head>
        <body>
        <h1>\(escape(Brand.appName))</h1>
        \(body)
        <footer>\(escape(Brand.appName)) \(escape(Brand.version)) · \(escape(Brand.creditLine))</footer>
        </body>
        </html>
        """
    }

    private static func xml(records: [HostRecord], options: ExportOptions) -> String {
        var items = ""
        for record in records {
            items += "    <host>\n"
            for column in options.columns {
                let tag = column.xmlTag
                items += "      <\(tag)>\(xmlEscape(record.text(for: column, format: options.display)))</\(tag)>\n"
            }
            items += "    </host>\n"
        }
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <pinginfoview>
          <application>\(xmlEscape(Brand.appName))</application>
          <version>\(xmlEscape(Brand.version))</version>
          <author>\(xmlEscape(Brand.author))</author>
          <website>\(xmlEscape(Brand.website))</website>
          <email>\(xmlEscape(Brand.email))</email>
          <generated>\(xmlEscape(ISO8601DateFormatter().string(from: Date())))</generated>
          <hosts>
        \(items)  </hosts>
        </pinginfoview>
        """
    }

    private static func field(_ value: String, separator: String) -> String {
        if value.contains(separator) || value.contains("\"") || value.contains("\n") || value.contains("\r") {
            return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
        }
        return value
    }

    private static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func xmlEscape(_ value: String) -> String {
        escape(value).replacingOccurrences(of: "'", with: "&apos;")
    }
}

struct ExportOptions: Equatable, Sendable {
    var columns: [ColumnID]
    var includeHeader: Bool
    var display: DisplayFormat

    static func from(_ settings: AppSettings, columns: [ColumnID]? = nil) -> ExportOptions {
        ExportOptions(
            columns: columns ?? ColumnID.allCases,
            includeHeader: settings.includeExportHeader,
            display: settings.displayFormat
        )
    }
}

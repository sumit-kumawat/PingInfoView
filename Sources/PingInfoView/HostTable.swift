import AppKit
import SwiftUI

private let cellPadding: CGFloat = 6
private let hiddenBadgeWidth: CGFloat = 34

extension View {
    @ViewBuilder
    func quietFocus() -> some View {
        if #available(macOS 14.0, *) {
            focusable().focusEffectDisabled()
        } else {
            focusable()
        }
    }
}

struct HostTable: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.colorScheme) private var colorScheme
    @StateObject private var visible = VisibleRows()

    var body: some View {
        GeometryReader { proxy in
            let gutter = ScrollerGutter.width
            let fit = fitColumns(width: proxy.size.width - gutter)
            let sections = TableSection.make(from: model.displayedRecords, model: model)
            VStack(spacing: 0) {
                header(fit, gutter: gutter)
                Divider()
                if sections.isEmpty {
                    emptyState
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Rectangle())
                        .onTapGesture { model.focusTable?() }
                } else {
                    ScrollViewReader { scroller in
                        ScrollView(.vertical) {
                            LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                                ForEach(sections) { section in
                                    if let name = section.group {
                                        Section {
                                            rows(section, fit: fit)
                                        } header: {
                                            banner(name, count: section.total)
                                        }
                                    } else {
                                        Section {
                                            rows(section, fit: fit)
                                        }
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity, minHeight: max(0, proxy.size.height - 28), alignment: .top)
                        }
                        .onChange(of: model.selectionLead) { lead in
                            guard let lead else { return }
                            let previous = visible.followed
                            visible.followed = lead
                            guard !visible.ids.contains(lead) else { return }
                            let order = model.visibleRows.map(\.id)
                            let anchor: UnitPoint
                            if let previous, let old = order.firstIndex(of: previous), let new = order.firstIndex(of: lead), new < old {
                                anchor = .top
                            } else {
                                anchor = .bottom
                            }
                            scroller.scrollTo(lead, anchor: anchor)
                        }
                    }
                }
            }
            .background(TableKeys(pageRows: pageCount(height: proxy.size.height)))
        }
        .background(model.settings.blackBackground ? Color.black : Color(nsColor: .controlBackgroundColor))
        .environment(\.colorScheme, model.settings.blackBackground ? .dark : colorScheme)
        .font(.system(size: model.settings.fontSize))
    }

    private var scale: CGFloat { CGFloat(model.settings.fontSize) / 13 }

    private var rowHeight: CGFloat { max(24, CGFloat(model.settings.fontSize) + 12) }

    private func pageCount(height: CGFloat) -> Int {
        max(1, Int((height - 28) / rowHeight) - 1)
    }

    private func fitColumns(width: CGFloat) -> ColumnFit<ColumnID> {
        let specs = model.settings.columns.map { column in
            ColumnSpec(id: column, minWidth: (column.minWidth * scale).rounded(.up), weight: column.weight, priority: column.priority)
        }
        let first = ColumnLayout.fit(specs, into: width)
        guard !first.hidden.isEmpty else { return first }
        return ColumnLayout.fit(specs, into: width - hiddenBadgeWidth)
    }

    private func header(_ fit: ColumnFit<ColumnID>, gutter: CGFloat) -> some View {
        HStack(spacing: 0) {
            ForEach(fit.columns, id: \.id) { column in
                Button { model.sort(by: column.id) } label: {
                    HStack(spacing: 3) {
                        Text(column.width < 90 ? column.id.shortTitle : column.id.title)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        if model.sortColumn == column.id {
                            Image(systemName: model.sortAscending ? "chevron.up" : "chevron.down")
                                .font(.system(size: 8, weight: .bold))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: column.id.isNumeric ? .trailing : .leading)
                    .padding(.horizontal, cellPadding)
                    .frame(width: column.width, height: 28)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Sort by \(column.id.title)")
            }
            if !fit.hidden.isEmpty {
                Text("+\(fit.hidden.count)")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.secondary.opacity(0.18)))
                    .frame(width: hiddenBadgeWidth)
                    .help("Hidden to fit the window: \(fit.hidden.map(\.title).joined(separator: ", ")). Widen the window, or turn columns off in Options → Display.")
            }
            Spacer(minLength: gutter)
        }
        .font(.system(size: max(11, model.settings.fontSize - 1), weight: .medium))
        .foregroundStyle(.secondary)
        .background(.bar)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: model.records.isEmpty ? "dot.radiowaves.left.and.right" : "line.3.horizontal.decrease.circle")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text(model.records.isEmpty ? "No hosts yet" : "No hosts match")
                .font(.title3.weight(.semibold))
            Text(model.records.isEmpty
                 ? "Add host names, IP addresses, ranges, or host:port in Ping Options."
                 : "Clear the filter or choose “All hosts” from the Show menu.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if model.records.isEmpty {
                Button("Ping Options…") { model.showOptions = true }
                    .padding(.top, 4)
            }
        }
        .padding(20)
    }

    @ViewBuilder
    private func rows(_ section: TableSection, fit: ColumnFit<ColumnID>) -> some View {
        ForEach(section.rows) { row in
            HostRow(record: row.record, stripe: row.stripe, fit: fit)
                .id(row.record.id)
                .onAppear { visible.ids.insert(row.record.id) }
                .onDisappear { visible.ids.remove(row.record.id) }
        }
    }

    private func banner(_ name: String, count: Int) -> some View {
        let collapsed = model.collapsedGroups.contains(name)
        return Button { model.toggleCollapsed(name) } label: {
            HStack(spacing: 8) {
                Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                    .font(.caption.weight(.bold))
                    .frame(width: 12)
                Text(name)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                Text("\(count)")
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 26, alignment: .leading)
            .background(.regularMaterial)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(collapsed ? "Show \(name)" : "Hide \(name)")
    }
}

private struct HostRow: View {
    @EnvironmentObject private var model: AppModel
    var record: HostRecord
    var stripe: Bool
    var fit: ColumnFit<ColumnID>

    var body: some View {
        HStack(spacing: 0) {
            ForEach(fit.columns, id: \.id) { column in
                cell(column.id)
                    .frame(maxWidth: .infinity, alignment: column.id.isNumeric ? .trailing : .leading)
                    .padding(.horizontal, cellPadding)
                    .frame(width: column.width)
            }
            Spacer(minLength: 0)
        }
        .frame(height: max(24, CGFloat(model.settings.fontSize) + 12))
        .background(background)
        .overlay(alignment: .leading) {
            if model.selection.contains(record.id) {
                Rectangle().fill(Color.accentColor).frame(width: 3)
            }
        }
        .opacity(record.enabled ? 1 : 0.45)
        .contentShape(Rectangle())
        .help(tooltip)
        .onTapGesture {
            let flags = NSEvent.modifierFlags
            model.select(record.id, command: flags.contains(.command), shift: flags.contains(.shift))
        }
        .contextMenu { menu }
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.primary.opacity(0.06)).frame(height: 1)
        }
    }

    private var tooltip: String {
        var lines = [record.target.endpointLabel]
        if !record.target.description.isEmpty { lines.append(record.target.description) }
        if let error = record.lastError, record.lastStatus == .down { lines.append(error) }
        return lines.joined(separator: "\n")
    }

    @ViewBuilder
    private func cell(_ column: ColumnID) -> some View {
        let text = record.text(for: column, format: model.settings.displayFormat)
        if column == .status {
            HStack(spacing: 5) {
                Circle().fill(statusColor).frame(width: 8, height: 8)
                Text(text).lineLimit(1).truncationMode(.tail)
            }
        } else if column.isNumeric {
            Text(text)
                .monospacedDigit()
                .lineLimit(1)
        } else {
            Text(text)
                .lineLimit(1)
                .truncationMode(column == .ipAddress || column == .replyIP ? .middle : .tail)
        }
    }

    private var background: Color {
        if model.selection.contains(record.id) { return Color.accentColor.opacity(0.28) }
        if record.enabled && record.lastStatus == .down { return Color.red.opacity(0.14) }
        if record.enabled && record.lastStatus == .up { return Color.green.opacity(0.07) }
        if stripe && model.settings.alternateRows { return Color.primary.opacity(0.04) }
        return Color.clear
    }

    private var statusColor: Color {
        if !record.enabled { return .gray }
        switch record.lastStatus {
        case .up: return .green
        case .down: return .red
        case .unknown: return .gray
        }
    }

    @ViewBuilder
    private var menu: some View {
        let targets = actionTargets
        let count = targets.count
        Button(count > 1 ? "Copy \(count) Host Names" : "Copy Host Name") {
            model.copyLines(targets.map(\.hostNameText), singular: "host name", plural: "host names")
        }
        Button(count > 1 ? "Copy \(count) IP Addresses" : "Copy IP Address") {
            model.copyLines(targets.map { $0.ipText.isEmpty ? $0.target.host : $0.ipText }, singular: "address", plural: "addresses")
        }
        Button(count > 1 ? "Copy \(count) Rows" : "Copy Row") { model.copyRows(targets) }
        Divider()
        Button("Select All") { model.selectAll() }
        Button("Deselect") { model.clearSelection() }
            .disabled(model.selection.isEmpty)
        Divider()
        Button(targets.allSatisfy(\.enabled) ? "Disable" : "Enable") {
            let turnOff = targets.allSatisfy(\.enabled)
            model.setEnabled(!turnOff, ids: Set(targets.map(\.id)))
        }
        Button("Ping in Terminal") { model.pingInTerminal(targets) }
        if !model.customMenu.isEmpty {
            Divider()
            ForEach(model.customMenu) { item in
                if item.isSeparator {
                    Divider()
                } else {
                    Button(item.title) { model.runCustom(item, rows: targets) }
                }
            }
        }
    }

    private var actionTargets: [HostRecord] {
        if model.selection.contains(record.id), model.selection.count > 1 {
            return model.records(for: model.selection)
        }
        return [record]
    }
}

struct TableRow: Identifiable {
    var record: HostRecord
    var stripe: Bool
    var id: UUID { record.id }
}

struct TableSection: Identifiable {
    static let ungrouped = "Ungrouped"

    var group: String?
    var total: Int
    var rows: [TableRow]

    var id: String { group.map { "group:\($0)" } ?? "all" }

    @MainActor
    static func make(from records: [HostRecord], model: AppModel) -> [TableSection] {
        guard !records.isEmpty else { return [] }
        let grouped = model.sortColumn == .order || model.sortColumn == .group
        let hasGroups = records.contains { !$0.target.group.isEmpty }
        guard grouped && hasGroups else {
            return [TableSection(
                group: nil,
                total: records.count,
                rows: records.enumerated().map { TableRow(record: $1, stripe: !$0.isMultiple(of: 2)) }
            )]
        }

        var order: [String] = []
        var buckets: [String: [HostRecord]] = [:]
        for record in records {
            let key = record.target.group
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(record)
        }
        var sections: [TableSection] = []
        var stripe = 0
        for key in order {
            let members = buckets[key] ?? []
            let name = key.isEmpty ? TableSection.ungrouped : key
            let collapsed = model.collapsedGroups.contains(name)
            var rows: [TableRow] = []
            if !collapsed {
                for record in members {
                    rows.append(TableRow(record: record, stripe: !stripe.isMultiple(of: 2)))
                    stripe += 1
                }
            }
            sections.append(TableSection(group: name, total: members.count, rows: rows))
        }
        return sections
    }
}

private enum HistoryColumn: String, CaseIterable, Hashable {
    case sentOn, status, ping, count, ttl, reply, detail

    var title: String {
        switch self {
        case .sentOn: "Sent On"
        case .status: "Status"
        case .ping: "Ping (ms)"
        case .count: "Count"
        case .ttl: "TTL"
        case .reply: "Reply"
        case .detail: "Detail"
        }
    }

    var spec: ColumnSpec<HistoryColumn> {
        switch self {
        case .sentOn: ColumnSpec(id: self, minWidth: 140, weight: 3, priority: 0)
        case .status: ColumnSpec(id: self, minWidth: 82, weight: 1, priority: 1)
        case .ping: ColumnSpec(id: self, minWidth: 70, weight: 1, priority: 2)
        case .detail: ColumnSpec(id: self, minWidth: 110, weight: 3, priority: 3)
        case .count: ColumnSpec(id: self, minWidth: 50, weight: 0.5, priority: 4)
        case .reply: ColumnSpec(id: self, minWidth: 104, weight: 2, priority: 5)
        case .ttl: ColumnSpec(id: self, minWidth: 44, weight: 0.5, priority: 6)
        }
    }

    var numeric: Bool { self == .ping || self == .count || self == .ttl }
}

struct HistoryPane: View {
    @EnvironmentObject private var model: AppModel

    private var record: HostRecord? {
        let preferred = model.selectionLead ?? model.selectionAnchor
        if let preferred, model.selection.contains(preferred) {
            return model.records.first { $0.id == preferred }
        }
        guard model.selection.count == 1, let id = model.selection.first else { return nil }
        return model.records.first { $0.id == id }
    }

    var body: some View {
        let current = record
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(title(current))
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                if let current {
                    Text("\(current.history.count) \(current.history.count == 1 ? "line" : "lines")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Copy") { model.copyHistory(current) }
                        .buttonStyle(.borderless)
                        .disabled(current.history.isEmpty)
                        .help("Copy this history")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(.bar)
            Divider()
            if let current {
                HistoryTable(record: current)
            } else {
                Text(model.settings.lowerPaneMode == .off
                     ? "History is turned off in Options → Export."
                     : "Select a host to see its ping history.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(12)
            }
        }
        .background(model.settings.blackBackground ? Color.black : Color(nsColor: .textBackgroundColor))
    }

    private func title(_ record: HostRecord?) -> String {
        guard let record else { return "History" }
        if record.target.description.isEmpty { return record.hostNameText }
        return "\(record.hostNameText) — \(record.target.description)"
    }
}

final class VisibleRows: ObservableObject {
    var ids: Set<UUID> = []
    var followed: UUID?
}

private struct HistoryTable: View {
    @EnvironmentObject private var model: AppModel
    var record: HostRecord

    var body: some View {
        GeometryReader { proxy in
            let gutter = ScrollerGutter.width
            let fit = ColumnLayout.fit(HistoryColumn.allCases.map(\.spec), into: proxy.size.width - gutter)
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    ForEach(fit.columns, id: \.id) { column in
                        Text(column.id.title)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: column.id.numeric ? .trailing : .leading)
                            .padding(.horizontal, cellPadding)
                            .frame(width: column.width, height: 22)
                    }
                    Spacer(minLength: gutter)
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .background(.bar)
                Divider()
                ScrollViewReader { scroller in
                    ScrollView(.vertical) {
                        LazyVStack(spacing: 0) {
                            ForEach(record.history) { entry in
                                row(entry, fit: fit).id(entry.id)
                            }
                        }
                    }
                    .onChange(of: record.history.last?.id) { last in
                        guard model.settings.autoScrollLowerPane, let last else { return }
                        scroller.scrollTo(last, anchor: .bottom)
                    }
                    .onAppear {
                        if model.settings.autoScrollLowerPane, let last = record.history.last?.id {
                            scroller.scrollTo(last, anchor: .bottom)
                        }
                    }
                }
            }
        }
    }

    private func row(_ entry: HistoryEntry, fit: ColumnFit<HistoryColumn>) -> some View {
        let format = model.settings.displayFormat
        return HStack(spacing: 0) {
            ForEach(fit.columns, id: \.id) { column in
                Group {
                    switch column.id {
                    case .sentOn: Text(entry.sentText(format: format))
                    case .status:
                        Text(entry.success ? "Succeeded" : "Failed")
                            .foregroundStyle(entry.success ? Color.green : Color.red)
                    case .ping: Text(format.milliseconds(entry.latencyMs))
                    case .count: Text("\(entry.count)")
                    case .ttl: Text(entry.ttl.map(String.init) ?? "")
                    case .reply: Text(entry.replyAddress ?? "")
                    case .detail: Text(entry.error ?? "")
                    }
                }
                .lineLimit(1)
                .truncationMode(.tail)
                .monospacedDigit()
                .frame(maxWidth: .infinity, alignment: column.id.numeric ? .trailing : .leading)
                .padding(.horizontal, cellPadding)
                .frame(width: column.width)
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: max(11, CGFloat(model.settings.fontSize) - 1)))
        .frame(height: 22)
        .background(entry.success ? Color.clear : Color.red.opacity(0.08))
    }
}

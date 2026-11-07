import Foundation

/// Which rows are selected, which row a Shift-range starts from, and which row the keyboard is on.
struct RowSelection: Equatable {
    var ids: Set<UUID> = []
    var anchor: UUID?
    var lead: UUID?

    mutating func click(_ id: UUID, command: Bool, shift: Bool, order: [UUID]) {
        if command, shift, let anchor, let range = Self.span(from: anchor, to: id, order: order) {
            ids.formUnion(range)
            lead = id
            return
        }
        if command {
            if ids.contains(id) {
                ids.remove(id)
            } else {
                ids.insert(id)
            }
            anchor = id
            lead = id
            return
        }
        if shift, let anchor, let range = Self.span(from: anchor, to: id, order: order) {
            ids = range
            lead = id
            return
        }
        ids = [id]
        anchor = id
        lead = id
    }

    mutating func move(by offset: Int, extending: Bool, order: [UUID]) {
        guard !order.isEmpty else { return }
        let index: Int
        if let origin = lead ?? anchor, let current = order.firstIndex(of: origin) {
            index = min(max(current + offset, 0), order.count - 1)
        } else {
            index = offset >= 0 ? 0 : order.count - 1
        }
        setLead(order[index], extending: extending, order: order)
    }

    mutating func jump(toEnd: Bool, extending: Bool, order: [UUID]) {
        guard !order.isEmpty else { return }
        setLead(order[toEnd ? order.count - 1 : 0], extending: extending, order: order)
    }

    mutating func selectAll(_ order: [UUID]) {
        guard !order.isEmpty else { return }
        ids = Set(order)
        if let anchor, !order.contains(anchor) { self.anchor = order[0] }
        if anchor == nil { anchor = order[0] }
        if let lead, !order.contains(lead) { self.lead = order[0] }
        if lead == nil { lead = order[0] }
    }

    mutating func clear() {
        ids = []
        anchor = nil
        lead = nil
    }

    private mutating func setLead(_ id: UUID, extending: Bool, order: [UUID]) {
        if extending {
            let pivot = anchor ?? id
            if let range = Self.span(from: pivot, to: id, order: order) {
                ids = range
                anchor = pivot
            } else {
                ids = [id]
                anchor = id
            }
        } else {
            ids = [id]
            anchor = id
        }
        lead = id
    }

    static func span(from start: UUID, to end: UUID, order: [UUID]) -> Set<UUID>? {
        guard let lower = order.firstIndex(of: start), let upper = order.firstIndex(of: end) else { return nil }
        return Set(order[min(lower, upper)...max(lower, upper)])
    }
}

enum TypeAhead {
    /// `names` is one display string per row. A single new character starts after the current row so repeating it walks the matches.
    static func match(buffer: String, names: [String], lead: Int?, continuing: Bool) -> Int? {
        let needle = buffer.lowercased()
        guard !needle.isEmpty, !names.isEmpty else { return nil }
        let start: Int
        if !continuing, let lead {
            start = (lead + 1) % names.count
        } else {
            start = lead ?? 0
        }
        for offset in 0..<names.count {
            let index = (start + offset) % names.count
            if names[index].lowercased().hasPrefix(needle) { return index }
        }
        return nil
    }
}

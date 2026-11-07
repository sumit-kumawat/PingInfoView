import AppKit
import CoreGraphics

struct ColumnSpec<ID: Hashable>: Equatable where ID: Equatable {
    var id: ID
    var minWidth: CGFloat
    var weight: CGFloat
    var priority: Int
}

struct FittedColumn<ID: Hashable>: Equatable {
    var id: ID
    var width: CGFloat
}

struct ColumnFit<ID: Hashable>: Equatable {
    var columns: [FittedColumn<ID>]
    var hidden: [ID]
}

enum ColumnLayout {
    /// Columns never exceed `width`, so the table never needs to scroll sideways.
    /// Low-priority columns are dropped first when even their minimum widths do not fit.
    static func fit<ID: Hashable>(_ specs: [ColumnSpec<ID>], into width: CGFloat) -> ColumnFit<ID> {
        let available = max(0, width.rounded(.down))
        var shown = specs
        var hidden: [ID] = []
        func minimum(_ list: [ColumnSpec<ID>]) -> CGFloat { list.reduce(0) { $0 + $1.minWidth } }

        while shown.count > 1 && minimum(shown) > available {
            var drop = 0
            for index in shown.indices where shown[index].priority >= shown[drop].priority {
                drop = index
            }
            hidden.append(shown[drop].id)
            shown.remove(at: drop)
        }

        let base = minimum(shown)
        let scale = base > available && base > 0 ? available / base : 1
        let extra = max(0, available - base)
        let weights = shown.reduce(0) { $0 + max(0, $1.weight) }
        var columns = shown.map { spec -> FittedColumn<ID> in
            let share = weights > 0 ? extra * max(0, spec.weight) / weights : 0
            return FittedColumn(id: spec.id, width: (spec.minWidth * scale + share).rounded(.down))
        }
        let used = columns.reduce(0) { $0 + $1.width }
        if let last = columns.indices.last, used < available {
            columns[last].width += available - used
        }
        return ColumnFit(columns: columns, hidden: hidden)
    }
}

enum ScrollerGutter {
    @MainActor
    static var width: CGFloat {
        NSScroller.preferredScrollerStyle == .legacy
            ? NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)
            : 0
    }
}

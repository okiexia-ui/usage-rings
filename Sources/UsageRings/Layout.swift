import Foundation

/// Fixed metrics for the side column so the panel can be sized before
/// SwiftUI lays out.
struct SideLayout {
    let size: RingSize
    let showLabels: Bool
    let rowCount: Int

    var ringDiameter: CGFloat { size.diameter }
    var labelHeight: CGFloat { showLabels ? 11 : 0 }
    var labelSpacing: CGFloat { showLabels ? 3 : 0 }
    var rowHeight: CGFloat { ringDiameter + labelSpacing + labelHeight }
    var rowSpacing: CGFloat { size == .small ? 7 : 9 }
    var horizontalPadding: CGFloat { 7 }
    var verticalPadding: CGFloat { 7 }
    var handleHeight: CGFloat { 10 }
    var handleSpacing: CGFloat { 5 }

    var columnWidth: CGFloat { max(ringDiameter, 30) + horizontalPadding * 2 }

    var columnHeight: CGFloat {
        let rows = CGFloat(max(1, rowCount))
        return verticalPadding * 2 + handleHeight + handleSpacing
            + rows * rowHeight + (rows - 1) * rowSpacing
    }

    static let tabWidth: CGFloat = 14
    static func tabHeight(rowCount: Int) -> CGFloat { 16 + CGFloat(max(1, rowCount)) * 10 }

    static let cardGap: CGFloat = 6
    static let cardWidth: CGFloat = 232
    static let screenInset: CGFloat = 5

    /// The largest layout no taller than `maxHeight`: smaller rings first,
    /// then no names, so a long list still fits on the screen.
    static func fitting(size: RingSize, showLabels: Bool, rowCount: Int, maxHeight: CGFloat?) -> SideLayout {
        let preferred = SideLayout(size: size, showLabels: showLabels, rowCount: rowCount)
        guard let maxHeight, preferred.columnHeight > maxHeight else { return preferred }
        let smaller = RingSize.allCases.filter { $0.diameter <= size.diameter }.sorted { $0.diameter > $1.diameter }
        for labels in Set([showLabels, false]).sorted(by: { $0 && !$1 }) {
            for candidate in smaller {
                let layout = SideLayout(size: candidate, showLabels: labels, rowCount: rowCount)
                if layout.columnHeight <= maxHeight { return layout }
            }
        }
        return SideLayout(size: .small, showLabels: false, rowCount: rowCount)
    }

    /// `cardHeight` is the open detail card's estimated height, nil when
    /// no card is showing.
    func panelSize(collapsed: Bool, cardHeight: CGFloat?) -> CGSize {
        if collapsed {
            return CGSize(width: Self.tabWidth, height: Self.tabHeight(rowCount: rowCount))
        }
        guard let cardHeight else {
            return CGSize(width: columnWidth, height: columnHeight)
        }
        return CGSize(
            width: columnWidth + Self.cardGap + Self.cardWidth,
            height: max(columnHeight, cardHeight)
        )
    }
}

/// Size and position of the camera housing on notched MacBooks; on other
/// displays the island hangs from the middle of the menu bar.
struct NotchGeometry: Equatable {
    var width: CGFloat
    var height: CGFloat
    /// Left edge of the notch, measured from the screen's left edge.
    var minX: CGFloat = 0

    var maxX: CGFloat { minX + width }
}

struct IslandLayout {
    let notch: NotchGeometry
    let rowCount: Int
    let maxWindows: Int
    /// Free menu-bar width right of the notch; nil = unconstrained.
    var rightSpace: CGFloat?
    /// Widest the expanded island may grow; nil = unconstrained.
    var maxWidth: CGFloat?

    static let miniSpacing: CGFloat = 7
    static let outerPadding: CGFloat = 9
    static let notchGap: CGFloat = 9
    static let emptyWing: CGFloat = 14
    static let columnWidth: CGFloat = 90
    static let expandedRing: CGFloat = 46
    static let rowGap: CGFloat = 10
    /// A lone provider puts its name and number in the right wing instead
    /// of leaving it empty.
    static let soloLabelWidth: CGFloat = 78

    private var count: Int { max(1, rowCount) }

    /// Collapsed rings fill the notch's height; many providers shrink a bit
    /// so the pill doesn't sprawl across the menu bar.
    var miniRing: CGFloat {
        let full = max(18, notch.height - 6)
        return count > 6 ? max(18, full - 4) : full
    }

    func ringsWidth(_ rings: Int) -> CGFloat {
        guard rings > 0 else { return Self.emptyWing }
        let n = CGFloat(rings)
        return Self.outerPadding + n * miniRing + (n - 1) * Self.miniSpacing + Self.notchGap
    }

    private var symmetricWing: CGFloat {
        let wing = ringsWidth((count + 1) / 2)
        return rowCount == 1 ? max(wing, Self.soloLabelWidth) : wing
    }

    /// Symmetric when the menu bar has room; otherwise the right wing keeps
    /// only what fits beside the status items and the rest moves left.
    var isSymmetric: Bool { symmetricWing <= (rightSpace ?? .infinity) }

    var rightCount: Int {
        if isSymmetric { return count - (count + 1) / 2 }
        var fit = 0
        while fit < count, ringsWidth(fit + 1) <= (rightSpace ?? 0) { fit += 1 }
        return min(fit, count - (count + 1) / 2)
    }

    var leftCount: Int { count - rightCount }
    var showsSoloLabel: Bool { rowCount == 1 && isSymmetric }

    var leftWing: CGFloat { isSymmetric ? symmetricWing : ringsWidth(leftCount) }
    var rightWing: CGFloat {
        if isSymmetric { return symmetricWing }
        return min(ringsWidth(rightCount), max(Self.emptyWing, rightSpace ?? 0))
    }

    var collapsedSize: CGSize {
        CGSize(width: leftWing + notch.width + rightWing, height: notch.height)
    }

    /// Columns per row of the expanded island: all of them, unless the
    /// screen is too narrow, in which case they wrap.
    var columnsPerRow: Int {
        guard let maxWidth else { return count }
        return max(1, min(count, Int((maxWidth - 36) / Self.columnWidth)))
    }

    var expandedRows: Int { (count + columnsPerRow - 1) / columnsPerRow }

    var expandedSize: CGSize {
        let lines = CGFloat(min(max(maxWindows, 1), 3))
        let column = Self.expandedRing + 5 + 15 + 4 + lines * 14 + 3 + 13 + 13
        let rows = CGFloat(expandedRows)
        return CGSize(
            width: max(collapsedSize.width, CGFloat(columnsPerRow) * Self.columnWidth + 36),
            height: notch.height + 10 + rows * column + (rows - 1) * Self.rowGap + 10 + 18 + 14
        )
    }
}

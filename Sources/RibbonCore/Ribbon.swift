import Foundation
import CoreGraphics

public struct Ribbon: Sendable, Codable {
    public var columns: [ColumnModel]
    public var activeColumnIndex: Int
    public var viewportOffset: Double
    public var isOverview: Bool

    public init(columns: [ColumnModel] = [], activeColumnIndex: Int = 0, viewportOffset: Double = 0, isOverview: Bool = false) {
        self.columns = columns
        self.activeColumnIndex = activeColumnIndex
        self.viewportOffset = viewportOffset
        self.isOverview = isOverview
    }

    public var activeColumn: ColumnModel? {
        guard !columns.isEmpty, columns.indices.contains(activeColumnIndex) else { return nil }
        return columns[activeColumnIndex]
    }

    public var activeWindow: WindowModel? {
        return activeColumn?.activeWindow
    }

    // MARK: - Navigation

    public mutating func focusLeft() {
        guard !columns.isEmpty else { return }
        activeColumnIndex = max(0, activeColumnIndex - 1)
    }

    public mutating func focusRight() {
        guard !columns.isEmpty else { return }
        activeColumnIndex = min(columns.count - 1, activeColumnIndex + 1)
    }

    public mutating func focusUp() {
        guard columns.indices.contains(activeColumnIndex) else { return }
        var col = columns[activeColumnIndex]
        if col.windows.count > 1 {
            col.activeRowIndex = max(0, col.activeRowIndex - 1)
            columns[activeColumnIndex] = col
        }
    }

    public mutating func focusDown() {
        guard columns.indices.contains(activeColumnIndex) else { return }
        var col = columns[activeColumnIndex]
        if col.windows.count > 1 {
            col.activeRowIndex = min(col.windows.count - 1, col.activeRowIndex + 1)
            columns[activeColumnIndex] = col
        }
    }

    public mutating func focusFirst() {
        guard !columns.isEmpty else { return }
        activeColumnIndex = 0
    }

    public mutating func focusLast() {
        guard !columns.isEmpty else { return }
        activeColumnIndex = columns.count - 1
    }

    // MARK: - Reordering & Manipulation

    public mutating func swapLeft() {
        guard activeColumnIndex > 0 else { return }
        columns.swapAt(activeColumnIndex, activeColumnIndex - 1)
        activeColumnIndex -= 1
    }

    public mutating func swapRight() {
        guard activeColumnIndex < columns.count - 1 else { return }
        columns.swapAt(activeColumnIndex, activeColumnIndex + 1)
        activeColumnIndex += 1
    }

    public mutating func swapUp() {
        guard columns.indices.contains(activeColumnIndex) else { return }
        var col = columns[activeColumnIndex]
        guard col.windows.count > 1, col.activeRowIndex > 0, col.activeRowIndex < col.windows.count else { return }
        col.windows.swapAt(col.activeRowIndex, col.activeRowIndex - 1)
        col.activeRowIndex -= 1
        columns[activeColumnIndex] = col
    }

    public mutating func swapDown() {
        guard columns.indices.contains(activeColumnIndex) else { return }
        var col = columns[activeColumnIndex]
        guard col.windows.count > 1, col.activeRowIndex >= 0, col.activeRowIndex < col.windows.count - 1 else { return }
        col.windows.swapAt(col.activeRowIndex, col.activeRowIndex + 1)
        col.activeRowIndex += 1
        columns[activeColumnIndex] = col
    }

    public mutating func moveFirst() {
        guard columns.indices.contains(activeColumnIndex), activeColumnIndex > 0 else { return }
        let col = columns.remove(at: activeColumnIndex)
        columns.insert(col, at: 0)
        activeColumnIndex = 0
    }

    public mutating func moveLast() {
        guard columns.indices.contains(activeColumnIndex), activeColumnIndex < columns.count - 1 else { return }
        let col = columns.remove(at: activeColumnIndex)
        columns.append(col)
        activeColumnIndex = columns.count - 1
    }

    /// The active column's width ratio as laid out: a lone column without an explicit width fills the canvas.
    public var effectiveWidthRatio: Double? {
        guard columns.indices.contains(activeColumnIndex) else { return nil }
        let isSingleAutoExpanded = (columns.count == 1 && !columns[0].hasExplicitSingleWidth)
        return isSingleAutoExpanded ? 1.0 : columns[activeColumnIndex].widthRatio
    }

    /// Changes the active column's width ratio by `delta`, clamped to [0.15, 1.0], and returns the
    /// change actually applied.
    @discardableResult
    public mutating func adjustWidth(by delta: Double) -> Double {
        guard let current = effectiveWidthRatio else { return 0.0 }
        // Rounding to a thousandth keeps repeated steps from drifting (0.5 + 0.1 + 0.1 - 0.2
        // lands below 0.5 and floors a pixel short).
        let newRatio = max(0.15, min(1.0, ((current + delta) * 1000).rounded() / 1000))
        // A clamped no-op keeps the stored ratio, which a lone auto-expanded column needs once a
        // second column joins.
        guard abs(newRatio - current) >= 0.0001 else { return 0.0 }
        columns[activeColumnIndex].widthRatio = newRatio
        if columns.count == 1 {
            columns[activeColumnIndex].hasExplicitSingleWidth = (abs(newRatio - 1.0) >= 0.01)
        }
        return newRatio - current
    }

    public mutating func cycleWidth(ratios: [Double]) {
        guard let effectiveCurrentRatio = effectiveWidthRatio else { return }

        let nextRatio: Double
        if let idx = ratios.firstIndex(where: { abs($0 - effectiveCurrentRatio) < 0.01 }) {
            let nextIndex = (idx + 1) % ratios.count
            nextRatio = ratios[nextIndex]
        } else {
            nextRatio = ratios.first ?? 0.5
        }

        columns[activeColumnIndex].widthRatio = nextRatio
        if columns.count == 1 {
            columns[activeColumnIndex].hasExplicitSingleWidth = (abs(nextRatio - 1.0) >= 0.01)
        }
    }

    /// Raises the window's minimum height; returns false when it is not in this ribbon or already that high.
    @discardableResult
    public mutating func raiseMinHeight(_ height: Double, forWindowID id: CGWindowID) -> Bool {
        for cIdx in columns.indices {
            guard let wIdx = columns[cIdx].windows.firstIndex(where: { $0.id == id }) else { continue }
            guard height > (columns[cIdx].windows[wIdx].minHeight ?? 0) else { return false }
            columns[cIdx].windows[wIdx].minHeight = height
            return true
        }
        return false
    }

    @discardableResult
    public mutating func setWidthRatio(_ ratio: Double, forWindowID id: CGWindowID) -> Bool {
        for (cIdx, col) in columns.enumerated() {
            if col.windows.contains(where: { $0.id == id }) {
                columns[cIdx].widthRatio = ratio
                if columns.count == 1 {
                    columns[cIdx].hasExplicitSingleWidth = (ratio < 0.98)
                }
                return true
            }
        }
        return false
    }

    public mutating func toggleOverview() {
        isOverview.toggle()
    }

    public mutating func slurp() {
        // Pull first window from right column into current column. Focus stays on the current
        // window: focusing the pulled window would activate its app, which blocks AX while it redraws.
        guard activeColumnIndex < columns.count - 1 else { return }
        let rightIndex = activeColumnIndex + 1
        var rightCol = columns[rightIndex]
        guard !rightCol.windows.isEmpty else { return }
        let win = rightCol.windows.removeFirst()
        columns[activeColumnIndex].windows.append(win)

        if rightCol.windows.isEmpty {
            columns.remove(at: rightIndex)
        } else {
            rightCol.activeRowIndex = max(0, min(rightCol.activeRowIndex, rightCol.windows.count - 1))
            columns[rightIndex] = rightCol
        }
    }

    public mutating func barf() {
        // Eject bottom window from current column into a new column to the right
        guard columns.indices.contains(activeColumnIndex) else { return }
        var col = columns[activeColumnIndex]
        guard col.windows.count > 1 else { return }
        let win = col.windows.removeLast()
        col.activeRowIndex = min(col.activeRowIndex, col.windows.count - 1)
        columns[activeColumnIndex] = col

        let newCol = ColumnModel(windows: [win], widthRatio: col.widthRatio)
        columns.insert(newCol, at: activeColumnIndex + 1)
    }

    // MARK: - Window Management

    @discardableResult
    public mutating func focus(windowID id: CGWindowID) -> Bool {
        for (cIdx, col) in columns.enumerated() {
            if let rIdx = col.windows.firstIndex(where: { $0.id == id }) {
                activeColumnIndex = cIdx
                var c = col
                c.activeRowIndex = rIdx
                columns[cIdx] = c
                return true
            }
        }
        return false
    }

    public mutating func addWindow(
        _ window: WindowModel,
        config: Config,
        activate: Bool = true,
        at index: Int? = nil,
        initialWidthRatio: Double? = nil
    ) {
        // Check if window is already tracked
        for (cIdx, col) in columns.enumerated() {
            if let rIdx = col.windows.firstIndex(where: { $0.id == window.id }) {
                if activate {
                    activeColumnIndex = cIdx
                    columns[cIdx].activeRowIndex = rIdx
                }
                return
            }
        }

        let configuredRatio = config.appWidthRatios[window.appName]
            ?? window.bundleId.flatMap { config.appWidthRatios[$0] }
        let defaultRatio = configuredRatio ?? config.defaultWidthRatio
        let rawRatio = initialWidthRatio ?? defaultRatio
        let isConfiguredFullWidth = (configuredRatio ?? 0.0) >= 0.95
        let ratio = (initialWidthRatio != nil && rawRatio >= 0.95 && !isConfiguredFullWidth)
            ? defaultRatio
            : rawRatio
        let newColumn = ColumnModel(
            windows: [window],
            widthRatio: ratio,
            hasExplicitSingleWidth: initialWidthRatio != nil && rawRatio < 0.95
        )

        if columns.isEmpty {
            columns.append(newColumn)
            activeColumnIndex = 0
        } else {
            if columns.count == 1 {
                columns[0].hasExplicitSingleWidth = false
            }
            let insertIndex: Int
            if let idx = index {
                insertIndex = min(max(0, idx), columns.count)
            } else if activate {
                insertIndex = min(activeColumnIndex + 1, columns.count)
            } else {
                insertIndex = columns.count
            }
            columns.insert(newColumn, at: insertIndex)
            if activate {
                activeColumnIndex = insertIndex
            } else if insertIndex <= activeColumnIndex {
                activeColumnIndex += 1
            }
        }
    }

    public mutating func removeWindow(id: CGWindowID) {
        for (cIdx, var col) in columns.enumerated() {
            if let rIdx = col.windows.firstIndex(where: { $0.id == id }) {
                col.windows.remove(at: rIdx)
                if col.windows.isEmpty {
                    columns.remove(at: cIdx)
                    if cIdx < activeColumnIndex {
                        activeColumnIndex -= 1
                    } else if cIdx == activeColumnIndex {
                        activeColumnIndex = max(0, cIdx - 1)
                    } else if activeColumnIndex >= columns.count {
                        activeColumnIndex = max(0, columns.count - 1)
                    }
                } else {
                    if rIdx < col.activeRowIndex {
                        col.activeRowIndex = max(0, col.activeRowIndex - 1)
                    } else {
                        col.activeRowIndex = max(0, min(col.activeRowIndex, col.windows.count - 1))
                    }
                    columns[cIdx] = col
                }
                return
            }
        }
    }

    public mutating func removeWindows(pid: pid_t) {
        let matchingIDs = columns.flatMap { $0.windows }.filter { $0.pid == pid }.map { $0.id }
        for id in matchingIDs {
            removeWindow(id: id)
        }
    }
}

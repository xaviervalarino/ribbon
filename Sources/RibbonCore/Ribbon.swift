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

    public mutating func cycleWidth(ratios: [Double]) {
        guard columns.indices.contains(activeColumnIndex) else { return }
        let isSingleAutoExpanded = (columns.count == 1 && !columns[0].hasExplicitSingleWidth)
        let effectiveCurrentRatio = isSingleAutoExpanded ? 1.0 : columns[activeColumnIndex].widthRatio

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
        // Pull first window from right column into current column
        guard activeColumnIndex < columns.count - 1 else { return }
        let rightIndex = activeColumnIndex + 1
        var rightCol = columns[rightIndex]
        guard !rightCol.windows.isEmpty else { return }
        let win = rightCol.windows.removeFirst()
        columns[activeColumnIndex].windows.append(win)
        columns[activeColumnIndex].activeRowIndex = columns[activeColumnIndex].windows.count - 1

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

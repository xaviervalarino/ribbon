import Foundation

public struct Ribbon: Sendable {
    public var columns: [ColumnModel]
    public var activeColumnIndex: Int

    public init(columns: [ColumnModel] = [], activeColumnIndex: Int = 0) {
        self.columns = columns
        self.activeColumnIndex = activeColumnIndex
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

    public mutating func cycleWidth(ratios: [Double]) {
        guard columns.indices.contains(activeColumnIndex) else { return }
        let currentRatio = columns[activeColumnIndex].widthRatio
        if let idx = ratios.firstIndex(where: { abs($0 - currentRatio) < 0.01 }) {
            let nextIndex = (idx + 1) % ratios.count
            columns[activeColumnIndex].widthRatio = ratios[nextIndex]
        } else {
            columns[activeColumnIndex].widthRatio = ratios.first ?? 0.5
        }
    }

    public mutating func slurp() {
        // Pull first window from right column into current column
        guard activeColumnIndex < columns.count - 1 else { return }
        let rightIndex = activeColumnIndex + 1
        var rightCol = columns[rightIndex]
        guard !rightCol.windows.isEmpty else { return }
        let win = rightCol.windows.removeFirst()
        columns[activeColumnIndex].windows.append(win)

        if rightCol.windows.isEmpty {
            columns.remove(at: rightIndex)
        } else {
            columns[rightIndex] = rightCol
        }
    }

    public mutating func barf() {
        // Eject active/bottom window from current column into a new column to the right
        guard columns.indices.contains(activeColumnIndex) else { return }
        var col = columns[activeColumnIndex]
        guard col.windows.count > 1 else { return }
        let win = col.windows.removeLast()
        columns[activeColumnIndex] = col

        let newCol = ColumnModel(windows: [win], widthRatio: col.widthRatio)
        columns.insert(newCol, at: activeColumnIndex + 1)
    }

    // MARK: - Window Management

    public mutating func addWindow(_ window: WindowModel, config: Config) {
        // Check if window is already tracked
        for (cIdx, col) in columns.enumerated() {
            if let rIdx = col.windows.firstIndex(where: { $0.id == window.id }) {
                activeColumnIndex = cIdx
                columns[cIdx].activeRowIndex = rIdx
                return
            }
        }

        let ratio = config.appWidthRatios[window.appName] ?? config.defaultWidthRatio
        let newColumn = ColumnModel(windows: [window], widthRatio: ratio)

        if columns.isEmpty {
            columns.append(newColumn)
            activeColumnIndex = 0
        } else {
            // Insert to the right of active column
            let insertIndex = min(activeColumnIndex + 1, columns.count)
            columns.insert(newColumn, at: insertIndex)
            activeColumnIndex = insertIndex
        }
    }

    public mutating func removeWindow(id: Int) {
        for (cIdx, var col) in columns.enumerated() {
            if let rIdx = col.windows.firstIndex(where: { $0.id == id }) {
                col.windows.remove(at: rIdx)
                if col.windows.isEmpty {
                    columns.remove(at: cIdx)
                    if activeColumnIndex >= columns.count {
                        activeColumnIndex = max(0, columns.count - 1)
                    }
                } else {
                    col.activeRowIndex = max(0, min(col.activeRowIndex, col.windows.count - 1))
                    columns[cIdx] = col
                }
                return
            }
        }
    }
}

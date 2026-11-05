import Foundation
import CoreGraphics

extension LayoutEngine {
    /// Lays `sizes` out in justified rows inside `bounds`, in order: each tile keeps its size's
    /// aspect ratio, every row has one height, and `gap` separates tiles and rows. The row count
    /// is the one giving the largest total tile area. A row is never taller than its shortest
    /// size, so no tile is larger than its window. Rows center horizontally and the block
    /// centers vertically. A size without area lays out as an uncapped square.
    public static func packedGrid(sizes: [CGSize], in bounds: CGRect, gap: Double) -> [CGRect] {
        let n = sizes.count
        guard n > 0 else { return [] }
        let aspects = sizes.map { $0.width > 0 && $0.height > 0 ? Double($0.width / $0.height) : 1 }
        let caps = sizes.map { $0.width > 0 && $0.height > 0 ? Double($0.height) : .infinity }
        let width = Double(bounds.width)
        let height = Double(bounds.height)

        /// The inverse of the tallest height at which items `i..<j` fit the width in one row.
        func cost(_ i: Int, _ j: Int) -> Double {
            let available = width - Double(j - i - 1) * gap
            guard available > 0 else { return .infinity }
            return aspects[i..<j].reduce(0, +) / available
        }

        // best[k][j]: the smallest worst-row cost splitting the first j items into k rows.
        // Ties keep the later split, so earlier rows hold more tiles.
        var best = Array(repeating: Array(repeating: Double.infinity, count: n + 1), count: n + 1)
        var split = Array(repeating: Array(repeating: 0, count: n + 1), count: n + 1)
        best[0][0] = 0
        for k in 1...n {
            for j in k...n {
                for i in (k - 1)..<j {
                    let worst = max(best[k - 1][i], cost(i, j))
                    if worst <= best[k][j] {
                        best[k][j] = worst
                        split[k][j] = i
                    }
                }
            }
        }

        var chosen: [(range: Range<Int>, height: Double)] = []
        var chosenArea = -1.0
        for rows in 1...n {
            var ranges: [Range<Int>] = []
            var end = n
            for k in stride(from: rows, to: 0, by: -1) {
                ranges.insert(split[k][end]..<end, at: 0)
                end = split[k][end]
            }
            let shared = min((height - Double(rows - 1) * gap) / Double(rows), 1 / best[rows][n])
            let laid = ranges.map { range in
                (range: range, height: max(0, min(shared, caps[range].min() ?? .infinity)))
            }
            let area = laid.reduce(0) { sum, row in
                sum + row.height * row.height * aspects[row.range].reduce(0, +)
            }
            if area > chosenArea {
                chosen = laid
                chosenArea = area
            }
        }

        let blockHeight = chosen.reduce(0) { $0 + $1.height } + Double(chosen.count - 1) * gap
        var y = Double(bounds.midY) - blockHeight / 2
        var frames: [CGRect] = []
        frames.reserveCapacity(n)
        for row in chosen {
            let rowWidth = aspects[row.range].reduce(0, +) * row.height + Double(row.range.count - 1) * gap
            var x = Double(bounds.midX) - rowWidth / 2
            for index in row.range {
                let tileWidth = aspects[index] * row.height
                frames.append(CGRect(x: x, y: y, width: tileWidth, height: row.height))
                x += tileWidth + gap
            }
            y += row.height + gap
        }
        return frames
    }
}

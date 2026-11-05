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
        let shapes = sizes.map { size -> (aspect: Double, cap: Double) in
            size.width > 0 && size.height > 0 ? (Double(size.width / size.height), Double(size.height)) : (1, .infinity)
        }
        let aspects = shapes.map(\.aspect)
        let caps = shapes.map(\.cap)
        // aspectSums[i]: the summed aspect of items `0..<i`.
        let aspectSums = aspects.reduce(into: [0.0]) { sums, aspect in sums.append(sums.last! + aspect) }
        /// The summed aspect of items `range`: a row's width at height 1, gaps aside.
        func aspectSum(_ range: Range<Int>) -> Double { aspectSums[range.upperBound] - aspectSums[range.lowerBound] }
        let width = Double(bounds.width)
        let height = Double(bounds.height)

        /// The inverse of the tallest height at which items `i..<j` fit the width in one row.
        func cost(_ i: Int, _ j: Int) -> Double {
            let available = width - Double(j - i - 1) * gap
            guard available > 0 else { return .infinity }
            return aspectSum(i..<j) / available
        }

        // best[k][j]: the smallest worst-row cost splitting the first j items into k rows.
        // Ties keep the later split, so earlier rows hold more tiles. A split only follows a
        // prefix that has a finite cost, so every split chain ends at item 0 and covers all
        // items even when no k-row split fits: those rows lay out at zero height.
        var best = Array(repeating: Array(repeating: Double.infinity, count: n + 1), count: n + 1)
        var split = Array(repeating: Array(repeating: 0, count: n + 1), count: n + 1)
        best[0][0] = 0
        for k in 1...n {
            for j in k...n {
                for i in (k - 1)..<j where best[k - 1][i].isFinite {
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
                sum + row.height * row.height * aspectSum(row.range)
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
            let rowWidth = aspectSum(row.range) * row.height + Double(row.range.count - 1) * gap
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

    /// The tile a `focus` direction moves to from `index` among `frames`, laid out as
    /// `packedGrid` lays them: left and right step through the order, up and down move to the
    /// tile in the adjacent row whose center is nearest horizontally (the earlier one on a tie),
    /// and first and last jump to the ends. The edges stay put. Nil for an unknown direction.
    public static func packedGridStep(frames: [CGRect], from index: Int, direction: String) -> Int? {
        let last = frames.count - 1
        let current = max(0, min(index, last))
        /// The tile nearest the current one horizontally in the row `rowOffset` rows away.
        func nearest(rowOffset: Int) -> Int {
            guard frames.indices.contains(current) else { return current }
            // Every tile in a packed row shares its top edge.
            let rowTops = frames.map(\.minY).reduce(into: [CGFloat]()) { tops, y in
                if tops.last != y { tops.append(y) }
            }
            guard let row = rowTops.firstIndex(of: frames[current].minY),
                  rowTops.indices.contains(row + rowOffset) else { return current }
            let midX = frames[current].midX
            return frames.indices
                .filter { frames[$0].minY == rowTops[row + rowOffset] }
                .min { abs(frames[$0].midX - midX) < abs(frames[$1].midX - midX) } ?? current
        }
        switch FocusDirection(direction) {
        case .left: return max(0, current - 1)
        case .right: return max(0, min(last, current + 1))
        case .up: return nearest(rowOffset: -1)
        case .down: return nearest(rowOffset: 1)
        case .first: return 0
        case .last: return max(0, last)
        case nil: return nil
        }
    }
}

import CoreGraphics
import Foundation

struct DependencyGraphEdge: Equatable {
    let parentID: DependencyNodeID
    let childID: DependencyNodeID
    let start: CGPoint
    let end: CGPoint
}

struct DependencyGraphLayout: Equatable {
    let frames: [DependencyNodeID: CGRect]
    let edges: [DependencyGraphEdge]
    let contentSize: CGSize
}

struct DependencyTreeLayout {
    let horizontalSpacing: CGFloat
    let verticalSpacing: CGFloat
    let contentPadding: CGFloat

    init(
        horizontalSpacing: CGFloat = 24,
        verticalSpacing: CGFloat = 64,
        contentPadding: CGFloat = 24
    ) {
        self.horizontalSpacing = horizontalSpacing
        self.verticalSpacing = verticalSpacing
        self.contentPadding = contentPadding
    }

    func layout(
        nodes: [DependencyGraphNode],
        sizes: [DependencyNodeID: CGSize]
    ) -> DependencyGraphLayout {
        guard let root = nodes.first else {
            return DependencyGraphLayout(frames: [:], edges: [], contentSize: .zero)
        }

        let nodeByID = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
        var childrenByParent: [DependencyNodeID: [DependencyGraphNode]] = [:]
        for node in nodes {
            if let parentID = node.parentID {
                childrenByParent[parentID, default: []].append(node)
            }
        }

        let defaultSize = CGSize(width: 100, height: 36)
        var subtreeWidths: [DependencyNodeID: CGFloat] = [:]

        func measure(_ id: DependencyNodeID) -> CGFloat {
            let nodeWidth = sizes[id, default: defaultSize].width
            let children = childrenByParent[id] ?? []
            let childrenWidth = children.enumerated().reduce(CGFloat.zero) { total, entry in
                total
                    + measure(entry.element.id)
                    + (entry.offset == 0 ? 0 : horizontalSpacing)
            }
            let width = max(nodeWidth, childrenWidth)
            subtreeWidths[id] = width
            return width
        }

        let totalTreeWidth = measure(root.id)
        let maxDepth = nodes.map(\.depth).max() ?? 0
        let rowHeights = Dictionary(grouping: nodes, by: \.depth).mapValues { row in
            row.map { sizes[$0.id, default: defaultSize].height }.max() ?? defaultSize.height
        }
        var rowOrigins: [Int: CGFloat] = [:]
        var nextY = contentPadding
        for depth in 0...maxDepth {
            rowOrigins[depth] = nextY
            nextY += rowHeights[depth, default: defaultSize.height] + verticalSpacing
        }

        var frames: [DependencyNodeID: CGRect] = [:]

        func place(_ id: DependencyNodeID, originX: CGFloat) {
            guard let node = nodeByID[id] else { return }
            let size = sizes[id, default: defaultSize]
            let subtreeWidth = subtreeWidths[id, default: size.width]
            frames[id] = CGRect(
                x: originX + (subtreeWidth - size.width) / 2,
                y: rowOrigins[node.depth, default: contentPadding],
                width: size.width,
                height: size.height
            )

            let children = childrenByParent[id] ?? []
            let childrenWidth = children.enumerated().reduce(CGFloat.zero) { total, entry in
                total
                    + subtreeWidths[entry.element.id, default: defaultSize.width]
                    + (entry.offset == 0 ? 0 : horizontalSpacing)
            }
            var childX = originX + (subtreeWidth - childrenWidth) / 2
            for child in children {
                place(child.id, originX: childX)
                childX += subtreeWidths[child.id, default: defaultSize.width] + horizontalSpacing
            }
        }

        place(root.id, originX: contentPadding)

        let edges = nodes.dropFirst().compactMap { child -> DependencyGraphEdge? in
            guard
                let parentID = child.parentID,
                let parentFrame = frames[parentID],
                let childFrame = frames[child.id]
            else { return nil }

            return DependencyGraphEdge(
                parentID: parentID,
                childID: child.id,
                start: CGPoint(x: parentFrame.midX, y: parentFrame.maxY),
                end: CGPoint(x: childFrame.midX, y: childFrame.minY)
            )
        }
        let contentHeight = (frames.values.map(\.maxY).max() ?? 0) + contentPadding

        return DependencyGraphLayout(
            frames: frames,
            edges: edges,
            contentSize: CGSize(
                width: totalTreeWidth + contentPadding * 2,
                height: contentHeight
            )
        )
    }
}

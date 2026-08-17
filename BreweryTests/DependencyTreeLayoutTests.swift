import XCTest
@testable import Brewery

@MainActor
final class DependencyTreeLayoutTests: XCTestCase {
    private let ordinarySize = CGSize(width: 100, height: 36)

    func testParentIsAboveEveryChild() {
        let nodes = branchingTree()
        let result = DependencyTreeLayout().layout(nodes: nodes, sizes: sizes(for: nodes))

        for edge in result.edges {
            guard
                let parentFrame = result.frames[edge.parentID],
                let childFrame = result.frames[edge.childID]
            else {
                return XCTFail("Every edge should reference positioned nodes")
            }

            XCTAssertLessThan(parentFrame.maxY, childFrame.minY)
            XCTAssertEqual(edge.start, CGPoint(x: parentFrame.midX, y: parentFrame.maxY))
            XCTAssertEqual(edge.end, CGPoint(x: childFrame.midX, y: childFrame.minY))
        }
    }

    func testSiblingFramesDoNotOverlap() {
        let nodes = branchingTree()
        let result = DependencyTreeLayout().layout(nodes: nodes, sizes: sizes(for: nodes))
        let siblingIDs = [id("root", "left"), id("root", "middle"), id("root", "right")]

        for firstIndex in siblingIDs.indices {
            for secondIndex in siblingIDs.indices where secondIndex > firstIndex {
                let firstFrame = try! XCTUnwrap(result.frames[siblingIDs[firstIndex]])
                let secondFrame = try! XCTUnwrap(result.frames[siblingIDs[secondIndex]])
                XCTAssertTrue(firstFrame.intersection(secondFrame).isNull)
            }
        }
    }

    func testParentIsCenteredOverChildSpan() throws {
        let nodes = branchingTree()
        let result = DependencyTreeLayout().layout(nodes: nodes, sizes: sizes(for: nodes))
        let parentFrame = try XCTUnwrap(result.frames[id("root")])
        let firstChildFrame = try XCTUnwrap(result.frames[id("root", "left")])
        let lastChildFrame = try XCTUnwrap(result.frames[id("root", "right")])

        XCTAssertEqual(
            parentFrame.midX,
            (firstChildFrame.minX + lastChildFrame.maxX) / 2,
            accuracy: 0.001
        )
    }

    func testLayoutIsDeterministic() {
        let nodes = branchingTree()
        let nodeSizes = sizes(for: nodes)
        let layout = DependencyTreeLayout()

        XCTAssertEqual(
            layout.layout(nodes: nodes, sizes: nodeSizes),
            layout.layout(nodes: nodes, sizes: nodeSizes)
        )
    }

    func testDeepSingleChildChainUsesOneColumn() throws {
        let nodes = [
            node(["root"]),
            node(["root", "one"]),
            node(["root", "one", "two"]),
            node(["root", "one", "two", "three"])
        ]
        let result = DependencyTreeLayout().layout(nodes: nodes, sizes: sizes(for: nodes))
        let centers = try nodes.map { try XCTUnwrap(result.frames[$0.id]).midX }

        for center in centers.dropFirst() {
            XCTAssertEqual(center, centers[0], accuracy: 0.001)
        }
    }

    func testLongNodeWidthsAffectSiblingSpacing() throws {
        let nodes = [
            node(["root"]),
            node(["root", "ordinary"]),
            node(["root", "a-much-longer-package-name"])
        ]
        var nodeSizes = sizes(for: nodes)
        nodeSizes[id("root", "a-much-longer-package-name")] = CGSize(width: 160, height: 36)
        let layout = DependencyTreeLayout(horizontalSpacing: 24)
        let result = layout.layout(nodes: nodes, sizes: nodeSizes)
        let ordinaryFrame = try XCTUnwrap(result.frames[id("root", "ordinary")])
        let longFrame = try XCTUnwrap(result.frames[id("root", "a-much-longer-package-name")])

        XCTAssertGreaterThanOrEqual(longFrame.minX - ordinaryFrame.maxX, 24)
        XCTAssertEqual(longFrame.width, 160)
    }

    private func branchingTree() -> [DependencyGraphNode] {
        [
            node(["root"]),
            node(["root", "left"]),
            node(["root", "middle"]),
            node(["root", "right"]),
            node(["root", "left", "left-child"]),
            node(["root", "right", "right-child"])
        ]
    }

    private func node(_ path: [String]) -> DependencyGraphNode {
        DependencyGraphNode(
            id: DependencyNodeID(path: path),
            parentID: path.count > 1 ? DependencyNodeID(path: Array(path.dropLast())) : nil,
            name: path.last ?? "",
            depth: path.count - 1,
            kind: .formula
        )
    }

    private func sizes(for nodes: [DependencyGraphNode]) -> [DependencyNodeID: CGSize] {
        Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, ordinarySize) })
    }

    private func id(_ path: String...) -> DependencyNodeID {
        DependencyNodeID(path: path)
    }
}

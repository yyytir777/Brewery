# Formula Dependency Graph Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the formula detail dependency buttons with an interactive, progressively expandable top-to-bottom dependency graph.

**Architecture:** Keep graph data/state, deterministic tree layout, and SwiftUI rendering in separate focused units. `DependencyGraphStore` owns path-based graph state and lazy loading, `DependencyTreeLayout` computes stable geometry, and `DependencyGraphView` composes real SwiftUI node views over Canvas-drawn edges. `BreweryViewModel` supplies a narrow async formula resolver while `BreweryDetailView` only embeds the component and forwards navigation.

**Tech Stack:** Swift 5, SwiftUI, Combine, XCTest, Xcode macOS app target, macOS 13.0; no new third-party dependencies.

## Global Constraints

- Keep `MACOSX_DEPLOYMENT_TARGET = 13.0`.
- Support Formula packages only; do not add Cask dependency graph behavior.
- Replace the existing formula dependency button list instead of duplicating it.
- Use a top-to-bottom hierarchy with direct dependencies visible initially.
- Keep the graph viewport at `320pt` high.
- Clamp zoom from `60%` through `180%` and provide drag, trackpad magnification, minus, reset, and plus controls.
- Use single click for selection, the disclosure button for expansion/collapse, and double click for detail navigation.
- Resolve deeper metadata lazily and cache it by formula name.
- Keep duplicate display paths distinct, prevent ancestry cycles, and limit the graph to 150 visible nodes.
- Add no third-party graph or layout library.
- Automated tests must use in-memory fixtures and must not execute mutating Homebrew commands.

---

## File Structure

- Create `Brewery/DependencyGraph/DependencyGraphModels.swift`: path IDs, display nodes, node state, load error, and formula-loader type alias.
- Create `Brewery/DependencyGraph/DependencyGraphStore.swift`: initial tree construction, selection, lazy expansion/collapse, cache, in-flight request sharing, cycle detection, failure/retry, and visible-node limit.
- Create `Brewery/DependencyGraph/DependencyTreeLayout.swift`: pure top-to-bottom subtree measurement, node positioning, content bounds, and edge endpoints.
- Create `Brewery/DependencyGraph/DependencyViewport.swift`: pure zoom clamping and offset adjustment needed to reveal newly expanded content.
- Create `Brewery/DependencyGraph/DependencyNodeView.swift`: accessible interactive node presentation.
- Create `Brewery/DependencyGraph/DependencyGraphView.swift`: fixed viewport, Canvas edges, node overlay, gestures, zoom controls, limit notice, and navigation.
- Create `BreweryTests/DependencyGraphFixtures.swift`: deterministic `BreweryFormula` factories for graph tests.
- Create `BreweryTests/DependencyGraphStoreTests.swift`: state, cache, duplicate, cycle, failure/retry, concurrent request, and limit tests.
- Create `BreweryTests/DependencyTreeLayoutTests.swift`: vertical ordering, no-overlap, centering, determinism, deep-chain, and long-label tests.
- Create `BreweryTests/DependencyViewportTests.swift`: zoom clamping and reveal-offset tests.
- Modify `Brewery/model/BrewViewModel.swift`: add `resolveFormulaForDependencyGraph(name:) async throws`.
- Modify `Brewery/View/BreweryDetailVeiw.swift`: replace `FlowLayout` dependency buttons with `DependencyGraphView` and remove the now-unused layout type.
- Modify `Brewery.xcodeproj/project.pbxproj`: add a macOS unit test bundle target using a file-system-synchronized `BreweryTests` group.
- Modify `Brewery.xcodeproj/xcshareddata/xcschemes/Brewery.xcscheme`: include `BreweryTests` in the shared scheme's test action.

---

### Task 1: Add the Test Target and Graph State Store

**Files:**
- Create: `Brewery/DependencyGraph/DependencyGraphModels.swift`
- Create: `Brewery/DependencyGraph/DependencyGraphStore.swift`
- Create: `BreweryTests/DependencyGraphFixtures.swift`
- Create: `BreweryTests/DependencyGraphStoreTests.swift`
- Modify: `Brewery.xcodeproj/project.pbxproj`
- Modify: `Brewery.xcodeproj/xcshareddata/xcschemes/Brewery.xcscheme`

**Interfaces:**
- Consumes: `BreweryFormula.name`, `BreweryFormula.dependencies`.
- Produces:
  - `struct DependencyNodeID: Hashable`
  - `struct DependencyGraphNode: Identifiable, Equatable`
  - `enum DependencyGraphNodeKind: Equatable`
  - `enum DependencyGraphNodeState: Equatable`
  - `enum DependencyGraphLoadError: LocalizedError, Equatable`
  - `typealias DependencyFormulaLoader = (String) async throws -> BreweryFormula`
  - `@MainActor final class DependencyGraphStore: ObservableObject`
  - `DependencyGraphStore.init(root:loader:maxVisibleNodes:)`
  - `DependencyGraphStore.visibleNodes: [DependencyGraphNode]`
  - `DependencyGraphStore.select(_:)`
  - `DependencyGraphStore.state(for:)`
  - `DependencyGraphStore.toggleExpansion(_:) async -> [DependencyNodeID]`
  - `DependencyGraphStore.retry(_:) async -> [DependencyNodeID]`

- [ ] **Step 1: Add a macOS unit test bundle to the project and shared scheme**

Add a file-system-synchronized root group at path `BreweryTests`, a `PBXNativeTarget` named `BreweryTests`, a unit-test product reference, Sources/Frameworks/Resources build phases, and a target dependency on the `Brewery` application target. Use `6FD100012FD0000000000001` as the new test target's `PBXNativeTarget` identifier so the scheme reference below is exact and stable.

Use these exact target settings for both Debug and Release, inheriting the remaining project defaults:

```text
BUNDLE_LOADER = $(TEST_HOST)
GENERATE_INFOPLIST_FILE = YES
MACOSX_DEPLOYMENT_TARGET = 13.0
PRODUCT_BUNDLE_IDENTIFIER = yyytir777.BreweryTests
PRODUCT_NAME = $(TARGET_NAME)
SDKROOT = macosx
SWIFT_VERSION = 5.0
TEST_HOST = $(BUILT_PRODUCTS_DIR)/Brewery.app/Contents/MacOS/Brewery
```

Add this `TestableReference` under the shared scheme's `TestAction`:

```xml
<Testables>
   <TestableReference
      skipped = "NO"
      parallelizable = "YES">
      <BuildableReference
         BuildableIdentifier = "primary"
         BlueprintIdentifier = "6FD100012FD0000000000001"
         BuildableName = "BreweryTests.xctest"
         BlueprintName = "BreweryTests"
         ReferencedContainer = "container:Brewery.xcodeproj">
      </BuildableReference>
   </TestableReference>
</Testables>
```

Do not alter the Brewery app target's build settings.

- [ ] **Step 2: Create formula fixtures and failing initial-state tests**

Create `BreweryTests/DependencyGraphFixtures.swift`:

```swift
import Foundation
@testable import Brewery

func makeFormula(_ name: String, dependencies: [String] = []) -> BreweryFormula {
    BreweryFormula(
        name: name,
        full_name: name,
        tap: "homebrew/core",
        desc: nil,
        homepage: "https://example.com/\(name)",
        license: nil,
        outdated: false,
        dependencies: dependencies,
        installed: [FormulaInstalled(version: "1.0", time: 0)],
        versions: FormulaVersions(stable: "1.0", head: nil, bottle: true)
    )
}
```

Create `BreweryTests/DependencyGraphStoreTests.swift` with an async `@MainActor` test class. Start with these tests:

```swift
import XCTest
@testable import Brewery

@MainActor
final class DependencyGraphStoreTests: XCTestCase {
    func testInitialTreeShowsRootAndDirectDependencies() {
        let root = makeFormula("git", dependencies: ["pcre2", "gettext"])
        let store = DependencyGraphStore(root: root) { name in makeFormula(name) }

        XCTAssertEqual(store.visibleNodes.map(\.name), ["git", "pcre2", "gettext"])
        XCTAssertEqual(store.visibleNodes.map(\.depth), [0, 1, 1])
        XCTAssertEqual(store.state(for: DependencyNodeID(path: ["git"])), .expanded)
    }

    func testSelectingNodeDoesNotExpandIt() {
        let store = DependencyGraphStore(root: makeFormula("git", dependencies: ["pcre2"])) { name in
            makeFormula(name, dependencies: ["child"])
        }
        let id = DependencyNodeID(path: ["git", "pcre2"])

        store.select(id)

        XCTAssertEqual(store.selectedNodeID, id)
        XCTAssertEqual(store.visibleNodes.map(\.name), ["git", "pcre2"])
    }
}
```

- [ ] **Step 3: Run the initial-state tests to verify they fail**

Run:

```bash
xcodebuild test -project Brewery.xcodeproj -scheme Brewery -destination 'platform=macOS' -only-testing:BreweryTests/DependencyGraphStoreTests
```

Expected: FAIL because `DependencyGraphStore`, `DependencyNodeID`, and related graph types do not exist.

- [ ] **Step 4: Add graph model types and the minimum initial store**

Create `DependencyGraphModels.swift` with these declarations:

```swift
import Foundation

struct DependencyNodeID: Hashable {
    let path: [String]
    var name: String { path.last ?? "" }
}

enum DependencyGraphNodeKind: Equatable {
    case formula
    case cycleReference
}

struct DependencyGraphNode: Identifiable, Equatable {
    let id: DependencyNodeID
    let parentID: DependencyNodeID?
    let name: String
    let depth: Int
    let kind: DependencyGraphNodeKind
}

enum DependencyGraphNodeState: Equatable {
    case collapsed
    case expanded
    case loading
    case leaf
    case failed(String)
    case cycleReference
}

enum DependencyGraphLoadError: LocalizedError, Equatable {
    case formulaUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .formulaUnavailable(let name):
            return "Could not load dependencies for \(name)."
        }
    }
}

typealias DependencyFormulaLoader = (String) async throws -> BreweryFormula
```

Create `DependencyGraphStore.swift` as an `@MainActor`, `ObservableObject` store. Initialize a root node plus direct children, cache the root formula, mark the root loaded and expanded, and expose a depth-first `visibleNodes` computed property. `select(_:)` only updates `selectedNodeID`.

- [ ] **Step 5: Run the initial-state tests to verify they pass**

Run the Task 1 test command again.

Expected: PASS for `testInitialTreeShowsRootAndDirectDependencies` and `testSelectingNodeDoesNotExpandIt`.

- [ ] **Step 6: Add failing expansion, caching, duplicate, cycle, retry, and limit tests**

Add tests with these exact scenarios:

```swift
func testExpansionLoadsChildrenAndCollapseHidesThem()
func testReexpansionUsesCachedFormula()
func testConcurrentDuplicatePathsShareOneLoaderTask()
func testSameFormulaUnderDifferentParentsHasDistinctPathIDs()
func testAncestryCycleCreatesNonExpandableReference()
func testFailureIsScopedToNodeAndRetryCanRecover()
func testExpansionBeyondVisibleLimitIsRejected()
```

Use an `actor LoaderProbe` in the test file to count calls and return results by name:

```swift
actor LoaderProbe {
    var results: [String: Result<BreweryFormula, Error>]
    private(set) var calls: [String: Int] = [:]

    init(results: [String: Result<BreweryFormula, Error>]) {
        self.results = results
    }

    func load(_ name: String) async throws -> BreweryFormula {
        calls[name, default: 0] += 1
        guard let result = results[name] else {
            throw DependencyGraphLoadError.formulaUnavailable(name)
        }
        return try result.get()
    }

    func setResult(_ result: Result<BreweryFormula, Error>, for name: String) {
        results[name] = result
    }

    func callCount(for name: String) -> Int { calls[name, default: 0] }
}
```

For the limit test, initialize `DependencyGraphStore(root:loader:maxVisibleNodes: 3)` with a root that has one direct child and a loaded child that has two dependencies. Assert the expansion returns an empty array, `visibleNodes.count == 2`, and `limitMessage != nil`.

- [ ] **Step 7: Run the extended tests to verify they fail**

Run the Task 1 test command.

Expected: FAIL because lazy loading, cache sharing, cycle detection, retry, and limit handling are incomplete.

- [ ] **Step 8: Implement the complete graph store**

Add these stored properties and behavior:

```swift
@Published private(set) var selectedNodeID: DependencyNodeID?
@Published private(set) var expandedNodeIDs: Set<DependencyNodeID>
@Published private(set) var loadingNodeIDs: Set<DependencyNodeID> = []
@Published private(set) var failures: [DependencyNodeID: String] = [:]
@Published private(set) var limitMessage: String?

private let loader: DependencyFormulaLoader
private let maxVisibleNodes: Int
private var nodesByID: [DependencyNodeID: DependencyGraphNode]
private var childrenByParent: [DependencyNodeID: [DependencyNodeID]]
private var loadedNodeIDs: Set<DependencyNodeID>
private var formulaCache: [String: BreweryFormula]
private var inFlightLoads: [String: Task<BreweryFormula, Error>] = [:]
```

Implement visible-node traversal so it visits children only when their parent is expanded. Preserve dependency-array order. Expansion must:

1. collapse immediately if the ID is already expanded;
2. reuse children already loaded for that path;
3. reuse formula metadata cached by name;
4. otherwise share the `Task` stored in `inFlightLoads[name]`;
5. create path IDs by appending the child name;
6. mark a child `.cycleReference` when the current path already contains that name;
7. reject the expansion when the candidate visible count exceeds `maxVisibleNodes`;
8. return only the IDs newly made visible, enabling the view to reveal them.

`retry(_:)` clears only that path's failure and calls the same expansion path. A cancellation error removes loading state without adding a failure. `state(for:)` returns state in this precedence order: cycle, loading, failed, expanded, loaded leaf, collapsed.

- [ ] **Step 9: Run store tests and commit**

Run:

```bash
xcodebuild test -project Brewery.xcodeproj -scheme Brewery -destination 'platform=macOS' -only-testing:BreweryTests/DependencyGraphStoreTests
```

Expected: PASS.

Commit only Task 1 files:

```bash
git add Brewery/DependencyGraph/DependencyGraphModels.swift Brewery/DependencyGraph/DependencyGraphStore.swift BreweryTests/DependencyGraphFixtures.swift BreweryTests/DependencyGraphStoreTests.swift Brewery.xcodeproj/project.pbxproj Brewery.xcodeproj/xcshareddata/xcschemes/Brewery.xcscheme
git commit -m "feat: add dependency graph state store"
```

---

### Task 2: Add the Deterministic Vertical Tree Layout

**Files:**
- Create: `Brewery/DependencyGraph/DependencyTreeLayout.swift`
- Create: `BreweryTests/DependencyTreeLayoutTests.swift`

**Interfaces:**
- Consumes: `[DependencyGraphNode]`, `[DependencyNodeID: CGSize]`.
- Produces:
  - `struct DependencyGraphEdge: Equatable`
  - `struct DependencyGraphLayout: Equatable`
  - `struct DependencyTreeLayout`
  - `DependencyTreeLayout.init(horizontalSpacing:verticalSpacing:contentPadding:)`
  - `DependencyTreeLayout.layout(nodes:sizes:) -> DependencyGraphLayout`

- [ ] **Step 1: Write failing vertical layout tests**

Create `DependencyTreeLayoutTests.swift` with helpers that build path-based nodes and constant sizes. Add these tests:

```swift
func testParentIsAboveEveryChild()
func testSiblingFramesDoNotOverlap()
func testParentIsCenteredOverChildSpan()
func testLayoutIsDeterministic()
func testDeepSingleChildChainUsesOneColumn()
func testLongNodeWidthsAffectSiblingSpacing()
```

Use `CGSize(width: 100, height: 36)` for ordinary nodes and `CGSize(width: 160, height: 36)` for the long-label fixture. For every edge, assert the parent frame's `maxY` is less than the child frame's `minY`. For sibling pairs, assert `frameA.intersection(frameB).isNull`.

- [ ] **Step 2: Run layout tests to verify they fail**

Run:

```bash
xcodebuild test -project Brewery.xcodeproj -scheme Brewery -destination 'platform=macOS' -only-testing:BreweryTests/DependencyTreeLayoutTests
```

Expected: FAIL because `DependencyTreeLayout` does not exist.

- [ ] **Step 3: Implement layout values and subtree algorithm**

Create these public-to-module values:

```swift
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
                total + measure(entry.element.id) + (entry.offset == 0 ? 0 : horizontalSpacing)
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
            let childrenTotal = children.enumerated().reduce(CGFloat.zero) { total, entry in
                total + subtreeWidths[entry.element.id, default: defaultSize.width]
                    + (entry.offset == 0 ? 0 : horizontalSpacing)
            }
            var childX = originX + (subtreeWidth - childrenTotal) / 2
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
```

Implement two pure passes:

1. Bottom-up subtree measurement: a leaf width is its node width; a parent width is `max(nodeWidth, sum(childWidths) + horizontalSpacing * (childCount - 1))`.
2. Top-down placement: give each subtree an x-range, center the parent in that range, place each depth at `contentPadding + depth * (nodeHeight + verticalSpacing)`, then recurse through children in input order.

Build each edge from `(parentFrame.midX, parentFrame.maxY)` to `(childFrame.midX, childFrame.minY)`. Include content padding in the returned bounds and return an empty layout for an empty node array.

- [ ] **Step 4: Run layout and store tests**

Run:

```bash
xcodebuild test -project Brewery.xcodeproj -scheme Brewery -destination 'platform=macOS' -only-testing:BreweryTests/DependencyTreeLayoutTests -only-testing:BreweryTests/DependencyGraphStoreTests
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Brewery/DependencyGraph/DependencyTreeLayout.swift BreweryTests/DependencyTreeLayoutTests.swift
git commit -m "feat: add dependency tree layout"
```

---

### Task 3: Add Viewport Math and the Interactive Graph UI

**Files:**
- Create: `Brewery/DependencyGraph/DependencyViewport.swift`
- Create: `Brewery/DependencyGraph/DependencyNodeView.swift`
- Create: `Brewery/DependencyGraph/DependencyGraphView.swift`
- Create: `BreweryTests/DependencyViewportTests.swift`

**Interfaces:**
- Consumes: `DependencyGraphStore`, `DependencyTreeLayout`, `DependencyFormulaLoader`, `(String) -> Void` navigation closure.
- Produces:
  - `struct DependencyViewport`
  - `DependencyViewport.clampedScale(_:) -> CGFloat`
  - `DependencyViewport.offsetToReveal(contentRect:viewportSize:scale:currentOffset:margin:) -> CGSize`
  - `struct DependencyNodeView: View`
  - `struct DependencyGraphView: View`

- [ ] **Step 1: Write failing viewport tests**

Create `DependencyViewportTests.swift`:

```swift
import XCTest
@testable import Brewery

final class DependencyViewportTests: XCTestCase {
    func testScaleIsClampedToSupportedRange() {
        XCTAssertEqual(DependencyViewport.clampedScale(0.2), 0.6)
        XCTAssertEqual(DependencyViewport.clampedScale(1.2), 1.2)
        XCTAssertEqual(DependencyViewport.clampedScale(2.4), 1.8)
    }

    func testVisibleRectKeepsCurrentOffset() {
        let offset = DependencyViewport.offsetToReveal(
            contentRect: CGRect(x: 40, y: 40, width: 80, height: 40),
            viewportSize: CGSize(width: 300, height: 200),
            scale: 1,
            currentOffset: CGSize(width: 0, height: 0),
            margin: 16
        )
        XCTAssertEqual(offset, .zero)
    }

    func testOffscreenBottomRectMovesCanvasUpOnlyAsNeeded() {
        let offset = DependencyViewport.offsetToReveal(
            contentRect: CGRect(x: 40, y: 220, width: 80, height: 40),
            viewportSize: CGSize(width: 300, height: 200),
            scale: 1,
            currentOffset: .zero,
            margin: 16
        )
        XCTAssertEqual(offset.height, -76, accuracy: 0.001)
    }
}
```

- [ ] **Step 2: Run viewport tests to verify they fail**

Run:

```bash
xcodebuild test -project Brewery.xcodeproj -scheme Brewery -destination 'platform=macOS' -only-testing:BreweryTests/DependencyViewportTests
```

Expected: FAIL because `DependencyViewport` does not exist.

- [ ] **Step 3: Implement pure viewport helpers**

Create `DependencyViewport.swift` with this pure implementation:

```swift
import SwiftUI

struct DependencyViewport {
    static func clampedScale(_ value: CGFloat) -> CGFloat {
        min(max(value, 0.6), 1.8)
    }

    static func offsetToReveal(
        contentRect: CGRect,
        viewportSize: CGSize,
        scale: CGFloat,
        currentOffset: CGSize,
        margin: CGFloat
    ) -> CGSize {
        let transformed = CGRect(
            x: contentRect.minX * scale + currentOffset.width,
            y: contentRect.minY * scale + currentOffset.height,
            width: contentRect.width * scale,
            height: contentRect.height * scale
        )
        var deltaX: CGFloat = 0
        var deltaY: CGFloat = 0

        if transformed.minX < margin {
            deltaX = margin - transformed.minX
        } else if transformed.maxX > viewportSize.width - margin {
            deltaX = viewportSize.width - margin - transformed.maxX
        }
        if transformed.minY < margin {
            deltaY = margin - transformed.minY
        } else if transformed.maxY > viewportSize.height - margin {
            deltaY = viewportSize.height - margin - transformed.maxY
        }

        return CGSize(
            width: currentOffset.width + deltaX,
            height: currentOffset.height + deltaY
        )
    }
}
```

- [ ] **Step 4: Run viewport tests to verify they pass**

Run the Task 3 viewport test command again.

Expected: PASS.

- [ ] **Step 5: Implement the accessible node view**

`DependencyNodeView` takes the node, `DependencyGraphNodeState`, selection flag, and four closures: `onSelect`, `onNavigate`, `onToggleExpansion`, and `onRetry`.

Render a rounded rectangle with:

- package name truncated to one line at a width between 88 and 160 points;
- a thicker accent border plus checkmark when selected;
- `ProgressView` while loading;
- a retry button with `exclamationmark.triangle` after failure;
- a disclosure button using `chevron.right` or `chevron.down` for collapsed/expanded nodes;
- no disclosure button for leaf or cycle-reference nodes;
- a circular-arrow indicator and help text for a cycle reference.

Apply the gestures in this order:

```swift
.onTapGesture(count: 2, perform: onNavigate)
.simultaneousGesture(TapGesture(count: 1).onEnded(onSelect))
```

Set `.help(node.name)`, an accessibility label containing the full name and depth, an accessibility value describing the node state, and `.accessibilityAddTraits(.isSelected)` when selected. Use real `Button` controls for disclosure and retry.

- [ ] **Step 6: Implement the fixed-height graph view**

Initialize `@StateObject` with `DependencyGraphStore(root:loader:)`. Hold persistent scale and offset in `@State`, transient magnification and drag values in `@GestureState`, and compute node widths from package-name length clamped from 88 through 160 points with a constant height of 36.

Inside a `GeometryReader` and clipped `GroupBox`:

1. calculate `DependencyGraphLayout` from `store.visibleNodes`;
2. draw cubic parent-child paths in a `Canvas` behind nodes;
3. position `DependencyNodeView` instances using layout frame midpoints;
4. apply effective scale and pan offset to the complete graph content;
5. attach `DragGesture` to empty background and `MagnificationGesture` to the viewport;
6. overlay `−`, `100%`, and `+` buttons at the lower trailing corner;
7. overlay `store.limitMessage` non-modally at the top;
8. keep the frame height exactly 320 points and clip overflow.

When `toggleExpansion` or `retry` returns newly visible IDs, union their layout frames and call `DependencyViewport.offsetToReveal` inside `withAnimation`. Reset sets scale to `1` and offsets the root frame to the viewport's horizontal center with 24 points of top padding.

- [ ] **Step 7: Build and run all graph unit tests**

Run:

```bash
xcodebuild test -project Brewery.xcodeproj -scheme Brewery -destination 'platform=macOS' -only-testing:BreweryTests/DependencyGraphStoreTests -only-testing:BreweryTests/DependencyTreeLayoutTests -only-testing:BreweryTests/DependencyViewportTests
```

Expected: PASS and the app target compiles with both new SwiftUI views.

- [ ] **Step 8: Commit**

```bash
git add Brewery/DependencyGraph/DependencyViewport.swift Brewery/DependencyGraph/DependencyNodeView.swift Brewery/DependencyGraph/DependencyGraphView.swift BreweryTests/DependencyViewportTests.swift
git commit -m "feat: add interactive dependency graph view"
```

---

### Task 4: Connect Homebrew Resolution and Replace the Detail Dependency List

**Files:**
- Modify: `Brewery/model/BrewViewModel.swift:41-47,151-157`
- Modify: `Brewery/View/BreweryDetailVeiw.swift:103-125,233-282`

**Interfaces:**
- Consumes: `DependencyGraphView.init(root:loader:onNavigate:)`, existing `fetchPackageInfo(name:isCask:)`, existing `BreweryDetailView.onNavigate`.
- Produces: `BreweryViewModel.resolveFormulaForDependencyGraph(name:) async throws -> BreweryFormula` and the live detail-screen integration.

- [ ] **Step 1: Add the formula resolver**

Add this method to `BreweryViewModel`:

```swift
func resolveFormulaForDependencyGraph(name: String) async throws -> BreweryFormula {
    if let installed = getFormula(for: name) {
        return installed
    }

    let info = await fetchPackageInfo(name: name, isCask: false)
    guard let formula = info.formula else {
        throw DependencyGraphLoadError.formulaUnavailable(name)
    }
    return formula
}
```

This preserves the installed formula map as the first-level cache. Do not change Cask loading.

- [ ] **Step 2: Replace the dependencies button group**

Replace the existing `GroupBox`/`FlowLayout` dependency content with:

```swift
DependencyGraphView(
    root: formula,
    loader: { name in
        try await vm.resolveFormulaForDependencyGraph(name: name)
    },
    onNavigate: onNavigate
)
.id(formula.name)
```

Keep the existing `Dependencies` heading and the `if !formula.dependencies.isEmpty` condition. Remove `FlowLayout` from the bottom of `BreweryDetailVeiw.swift` because it has no remaining callers. Do not alter the Cask detail section.

- [ ] **Step 3: Build the app and run all tests**

Run:

```bash
xcodebuild build -project Brewery.xcodeproj -scheme Brewery -destination 'platform=macOS'
xcodebuild test -project Brewery.xcodeproj -scheme Brewery -destination 'platform=macOS'
```

Expected: both commands exit 0; all dependency graph tests pass.

- [ ] **Step 4: Commit**

```bash
git add Brewery/model/BrewViewModel.swift Brewery/View/BreweryDetailVeiw.swift
git commit -m "feat: show formula dependency graph"
```

---

### Task 5: Verify Interaction, Appearance, Accessibility, and Repository Scope

**Files:**
- Modify if verification exposes a defect: only files created or modified in Tasks 1-4.

**Interfaces:**
- Consumes: completed dependency graph feature.
- Produces: verified macOS 13-compatible implementation with no unrelated changes.

- [ ] **Step 1: Run focused and full automated verification**

Run:

```bash
xcodebuild test -project Brewery.xcodeproj -scheme Brewery -destination 'platform=macOS' -only-testing:BreweryTests/DependencyGraphStoreTests -only-testing:BreweryTests/DependencyTreeLayoutTests -only-testing:BreweryTests/DependencyViewportTests
xcodebuild build -project Brewery.xcodeproj -scheme Brewery -configuration Debug -destination 'platform=macOS'
xcodebuild build -project Brewery.xcodeproj -scheme Brewery -configuration Release -destination 'platform=macOS'
```

Expected: all three commands exit 0 with no graph-related warnings.

- [ ] **Step 2: Launch and inspect at the supported sizes**

Open the Debug app produced by Xcode and inspect an installed Formula with at least two direct dependencies at:

```text
Default window: 900 × 600
Minimum detail width: 380pt
Appearance: Light and Dark
```

Confirm the dependency graph is exactly 320 points high, clipped inside its group, readable at both widths, and does not change the Cask detail screen.

- [ ] **Step 3: Exercise every interaction and state**

Verify:

```text
Single click: selects only and shows non-color selection indication
Disclosure: expands/collapses without navigation
Double click: navigates to the dependency detail
Background drag: pans without triggering a node
Trackpad magnification: remains within 60%-180%
Minus/reset/plus: keyboard reachable and update scale
Expansion: brings new children into view with minimal movement
Leaf: loses disclosure after metadata resolves with no dependencies
Failure: leaves other branches intact and exposes Retry
Cycle reference: remains connected and cannot expand
150-node limit: keeps current graph and shows a non-modal explanation
```

Use VoiceOver or Accessibility Inspector to confirm full package names, depth/state values, selected trait, and button labels are announced.

- [ ] **Step 4: Review the final diff for scope and generated files**

Run:

```bash
git diff --check
git status --short
git diff -- Brewery BreweryTests Brewery.xcodeproj
```

Expected: no whitespace errors; only dependency graph implementation/test/project files are part of this feature. Preserve the user's pre-existing `.gitignore`, `docs/superpowers/plans/`, and `scripts/` changes. Do not add `.superpowers/` visual-companion artifacts to a feature commit.

- [ ] **Step 5: Commit verification fixes only if Step 2 or 3 required changes**

If verification required code changes, rerun Step 1 and commit only those focused files:

```bash
git add Brewery/DependencyGraph BreweryTests Brewery/model/BrewViewModel.swift Brewery/View/BreweryDetailVeiw.swift Brewery.xcodeproj/project.pbxproj Brewery.xcodeproj/xcshareddata/xcschemes/Brewery.xcscheme
git commit -m "fix: polish dependency graph interactions"
```

If verification required no changes, do not create an empty commit.

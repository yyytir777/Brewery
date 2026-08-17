# Formula Dependency Graph Design

**Date:** 2026-08-16

**Status:** Approved

## Goal

Replace the formula detail screen's dependency button list with an interactive node graph. The graph lets users inspect direct dependencies immediately, progressively reveal transitive dependencies, and navigate to an installed dependency's detail screen without leaving the graph accidentally.

## Scope

### Included

- Formula packages only.
- A top-to-bottom hierarchical graph embedded in `BreweryDetailView`.
- Direct dependencies visible on initial render.
- Lazy expansion and collapse of transitive dependencies.
- Node selection, double-click navigation, canvas pan, and zoom.
- Loading, retry, cycle protection, duplicate dependency handling, and a visible-node safety limit.
- Unit tests for graph state and layout behavior.

### Excluded

- Cask dependency visualization.
- Automatic expansion of the complete transitive graph.
- Force-directed or radial graph layouts.
- Editing package relationships.
- Third-party graph or layout libraries.

## Existing Integration

`BreweryDetailView` already receives the selected formula and an `onNavigate(String)` closure. The current `Dependencies` section renders `formula.dependencies` as buttons in a `FlowLayout`.

The new graph replaces that button list rather than appearing beside duplicate dependency controls. It remains inside the existing detail `ScrollView`, under the `Dependencies` heading. Formulae without dependencies do not show the section.

Double-clicking a dependency calls the existing `onNavigate` closure. `MainView` continues to own package selection and recreates the detail view when the selected package changes.

## Component Architecture

### `DependencyGraphView`

Owns the graph presentation and viewport interaction. Its public inputs are:

- the root `BreweryFormula`;
- an asynchronous formula loader;
- an `onNavigate(String)` closure.

It renders a fixed-height graph surface, overlays interactive node views on calculated positions, draws edges behind them, and applies the current pan and zoom transforms.

### `DependencyNodeView`

Renders one package node. It is responsible only for presentation and emitting user intents:

- select on a single click;
- navigate on a double click;
- expand or collapse from a dedicated disclosure control;
- retry after a load failure.

The node shows selection, loading, failure, leaf, and cycle-reference states. Long names are truncated at the node's maximum width and exposed in a tooltip and accessibility label.

### `DependencyGraphStore`

Owns graph state independently from drawing and layout:

- the root and visible path-based nodes;
- the selected node path;
- expanded node paths;
- per-package formula cache;
- per-path loading and failure state;
- the 150-visible-node limit.

Package metadata is cached by formula name. Display nodes are identified by their full ancestry path, allowing the same formula to appear beneath multiple parents without duplicating metadata or confusing expansion state.

The store accepts an asynchronous loader closure instead of depending directly on `BreweryViewModel`. Tests can therefore use deterministic in-memory formula fixtures.

### `DependencyTreeLayout`

Is a pure layout unit. Given visible path-based nodes and measured node sizes, it returns:

- a position for every visible node;
- the total content bounds;
- parent-child edge endpoints.

The algorithm lays out leaves from left to right, centers each parent over the span of its visible children, and assigns each depth to a vertical level. It preserves stable sibling ordering from the Homebrew dependency array. It must be deterministic and prevent sibling rectangles from overlapping.

### `BreweryViewModel`

Provides a narrow formula resolver for the graph. Resolution checks the installed formula map first and only invokes `brew info --json=v2 <name>` when the formula is not already cached by the view model. A failed command or undecodable response is returned as a load failure so the graph can display retry UI.

## Data Flow

1. `BreweryDetailView` supplies its `BreweryFormula` to `DependencyGraphView`.
2. The store creates the root node and one child node for every direct dependency. These nodes are visible immediately.
3. When a disclosure control is pressed, the store collapses an expanded path or begins expansion of a collapsed path.
4. Expansion first checks the store's metadata cache, then asks the view-model-backed loader to resolve the formula.
5. While resolution is in progress, only the initiating node displays an inline progress indicator.
6. On success, the formula's dependencies become child nodes and the result is cached by package name.
7. On failure, the current graph remains intact and the node displays a retry control.
8. After a successful expansion, the viewport adjusts only as much as needed to make the newly added children visible.
9. Selecting a different detail package recreates the graph and resets selection, expansion, pan, and zoom state.

Concurrent requests for the same formula share one in-flight load. Repeated expansion after a successful load does not run another Homebrew command.

## Duplicate and Cycle Handling

A Homebrew dependency graph is a directed acyclic graph in normal operation, but the UI must remain safe when data is malformed.

- If two parents depend on the same formula, both paths render their own node.
- Both nodes reuse metadata cached under the formula name.
- Before adding children, the store checks the current node's ancestry.
- A child whose formula name already exists in that ancestry is rendered as a cycle reference.
- A cycle-reference node keeps its connecting edge but cannot be expanded.

## Layout and Viewport

- Graph viewport height: `320pt`.
- Layout direction: root at the top, dependencies below.
- Initial scale: `100%`.
- Allowed scale: `60%` through `180%`.
- Empty-background drag pans the canvas.
- Trackpad magnification changes scale.
- A compact `− / reset / +` control provides mouse and keyboard alternatives.
- Reset restores `100%` scale and centers the root.
- Node interaction takes precedence over the background pan gesture.
- Edges connect the bottom center of a parent to the top center of each child.
- Expansion and the minimum necessary viewport adjustment are animated.

The graph surface is clipped to its rounded `GroupBox` bounds. The fixed viewport prevents a deep graph from making the formula detail page excessively tall.

## Node Interaction

- A single click selects and visually emphasizes a node.
- The disclosure control expands or collapses children without changing detail selection.
- A double click invokes `onNavigate` for that formula.
- The root and direct dependencies appear on initial render; deeper levels appear only after explicit expansion.
- A node whose metadata has loaded and has no dependencies is presented as a leaf without a disclosure control.
- Before metadata is loaded, a non-root dependency may show a disclosure control because its leaf status is not yet known.

Brief selection before a double-click navigation is acceptable and keeps single-click behavior responsive.

## Limits and Failure States

The graph supports arbitrary dependency depth through manual expansion, subject to a maximum of 150 visible nodes.

- An expansion that would exceed 150 visible nodes is not applied.
- Existing visible nodes and viewport state remain unchanged.
- The graph shows a non-modal explanation that the visible-node limit was reached.
- Collapsing another branch permits later expansion elsewhere.
- Load failure affects only the initiating node and does not clear successful branches.
- Retry repeats the failed resolution and retains all unrelated graph state.
- Cancellation caused by leaving the detail screen does not surface as an error.

## Accessibility

- Every node exposes its full package name and state through an accessibility label and value.
- Disclosure and retry actions use real SwiftUI buttons with descriptive labels.
- Zoom controls are keyboard reachable.
- Selection is conveyed with more than color alone, using border weight and an accessibility selected trait.
- Lines are supplementary; the hierarchy remains available through node accessibility relationships and labels.

## Testing

Add a macOS unit test target named `BreweryTests` if the project still has no test target.

### Store tests

- The root and direct dependencies are visible immediately.
- Expanding and collapsing affects only the chosen path.
- Re-expansion reuses cached metadata.
- Concurrent paths requesting the same formula share one load.
- Duplicate formulas render under each parent while sharing metadata.
- An ancestry cycle becomes a non-expandable reference node.
- Failure is isolated to the initiating node and retry can recover.
- An expansion beyond 150 visible nodes is rejected without corrupting state.

### Layout tests

- Every parent is above each visible child.
- Sibling rectangles do not overlap.
- A parent is horizontally centered over its visible child span.
- Equal inputs produce equal positions and content bounds.
- Single-child, wide-sibling, deep-chain, duplicate-node, and long-label fixtures remain valid.

### Manual verification

- Minimum supported detail width and the default `900 × 600` window.
- Light and dark appearance.
- Mouse and trackpad pan/zoom behavior.
- Single click, disclosure click, double click, and retry do not interfere with one another.
- A large graph stays responsive and clipped within the 320-point viewport.

Automated tests use in-memory fixtures and must not execute destructive or mutating Homebrew commands.

## Success Criteria

- Users can see a formula's direct dependencies without interaction.
- Users can progressively inspect deeper relationships without loading the entire graph up front.
- The dependency direction is visually clear in a vertical hierarchy.
- Graph exploration does not accidentally navigate away on a single click.
- Repeated exploration avoids redundant Homebrew commands.
- Deep, duplicate, cyclic, failed, and oversized data cannot break the detail screen.
- The feature works on the existing macOS 13.0 deployment target without third-party dependencies.

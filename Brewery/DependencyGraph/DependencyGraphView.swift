import SwiftUI

struct DependencyGraphView: View {
    @StateObject private var store: DependencyGraphStore

    private let onNavigate: (String) -> Void
    private let treeLayout = DependencyTreeLayout()

    @State private var scale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var hasPositionedRoot = false
    @GestureState private var dragTranslation: CGSize = .zero
    @GestureState private var magnification: CGFloat = 1

    init(
        root: BreweryFormula,
        loader: @escaping DependencyFormulaLoader,
        onNavigate: @escaping (String) -> Void
    ) {
        _store = StateObject(wrappedValue: DependencyGraphStore(root: root, loader: loader))
        self.onNavigate = onNavigate
    }

    var body: some View {
        GroupBox {
            GeometryReader { proxy in
                let nodes = store.visibleNodes
                let layout = graphLayout(for: nodes)

                ZStack(alignment: .topLeading) {
                    Rectangle()
                        .fill(.clear)
                        .contentShape(Rectangle())
                        .gesture(panGesture)

                    graphContent(nodes: nodes, layout: layout, viewportSize: proxy.size)
                        .scaleEffect(effectiveScale, anchor: .topLeading)
                        .offset(effectiveOffset)

                    if let limitMessage = store.limitMessage {
                        Text(limitMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(.regularMaterial, in: Capsule())
                            .frame(maxWidth: .infinity)
                            .padding(.top, 8)
                            .allowsHitTesting(false)
                    }

                    zoomControls(layout: layout, viewportSize: proxy.size)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                        .padding(8)
                }
                .clipped()
                .simultaneousGesture(magnificationGesture)
                .onAppear {
                    guard !hasPositionedRoot else { return }
                    resetViewport(layout: layout, viewportSize: proxy.size)
                    hasPositionedRoot = true
                }
            }
        }
        .frame(height: 320)
    }

    private func graphContent(
        nodes: [DependencyGraphNode],
        layout: DependencyGraphLayout,
        viewportSize: CGSize
    ) -> some View {
        ZStack(alignment: .topLeading) {
            Canvas { context, _ in
                for edge in layout.edges {
                    var path = Path()
                    let midpointY = (edge.start.y + edge.end.y) / 2
                    path.move(to: edge.start)
                    path.addCurve(
                        to: edge.end,
                        control1: CGPoint(x: edge.start.x, y: midpointY),
                        control2: CGPoint(x: edge.end.x, y: midpointY)
                    )
                    context.stroke(
                        path,
                        with: .color(.secondary.opacity(0.45)),
                        style: StrokeStyle(lineWidth: 1.5, lineCap: .round)
                    )
                }
            }
            .frame(width: layout.contentSize.width, height: layout.contentSize.height)
            .allowsHitTesting(false)

            ForEach(nodes) { node in
                if let frame = layout.frames[node.id] {
                    DependencyNodeView(
                        node: node,
                        state: store.state(for: node.id),
                        isSelected: store.selectedNodeID == node.id,
                        onSelect: { store.select(node.id) },
                        onNavigate: { onNavigate(node.name) },
                        onToggleExpansion: {
                            Task {
                                let revealedIDs = await store.toggleExpansion(node.id)
                                reveal(
                                    revealedIDs,
                                    viewportSize: viewportSize
                                )
                            }
                        },
                        onRetry: {
                            Task {
                                let revealedIDs = await store.retry(node.id)
                                reveal(
                                    revealedIDs,
                                    viewportSize: viewportSize
                                )
                            }
                        }
                    )
                    .frame(width: frame.width, height: frame.height)
                    .position(x: frame.midX, y: frame.midY)
                }
            }
        }
        .frame(width: layout.contentSize.width, height: layout.contentSize.height, alignment: .topLeading)
    }

    private func zoomControls(
        layout: DependencyGraphLayout,
        viewportSize: CGSize
    ) -> some View {
        HStack(spacing: 0) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) {
                    scale = DependencyViewport.clampedScale(scale - 0.2)
                }
            } label: {
                Image(systemName: "minus")
                    .frame(width: 24, height: 22)
            }
            .help("Zoom out")
            .disabled(scale <= 0.6)

            Divider()
                .frame(height: 16)

            Button {
                withAnimation(.easeOut(duration: 0.2)) {
                    resetViewport(layout: layout, viewportSize: viewportSize)
                }
            } label: {
                Text("\(Int((scale * 100).rounded()))%")
                    .font(.caption.monospacedDigit())
                    .frame(minWidth: 42, minHeight: 22)
            }
            .help("Reset zoom and position")

            Divider()
                .frame(height: 16)

            Button {
                withAnimation(.easeOut(duration: 0.15)) {
                    scale = DependencyViewport.clampedScale(scale + 0.2)
                }
            } label: {
                Image(systemName: "plus")
                    .frame(width: 24, height: 22)
            }
            .help("Zoom in")
            .disabled(scale >= 1.8)
        }
        .buttonStyle(.plain)
        .padding(4)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(.separator.opacity(0.6), lineWidth: 1)
        }
    }

    private var panGesture: some Gesture {
        DragGesture(minimumDistance: 2)
            .updating($dragTranslation) { value, state, _ in
                state = value.translation
            }
            .onEnded { value in
                offset.width += value.translation.width
                offset.height += value.translation.height
            }
    }

    private var magnificationGesture: some Gesture {
        MagnificationGesture()
            .updating($magnification) { value, state, _ in
                state = value
            }
            .onEnded { value in
                scale = DependencyViewport.clampedScale(scale * value)
            }
    }

    private var effectiveScale: CGFloat {
        DependencyViewport.clampedScale(scale * magnification)
    }

    private var effectiveOffset: CGSize {
        CGSize(
            width: offset.width + dragTranslation.width,
            height: offset.height + dragTranslation.height
        )
    }

    private func graphLayout(for nodes: [DependencyGraphNode]) -> DependencyGraphLayout {
        treeLayout.layout(nodes: nodes, sizes: nodeSizes(for: nodes))
    }

    private func nodeSizes(for nodes: [DependencyGraphNode]) -> [DependencyNodeID: CGSize] {
        Dictionary(uniqueKeysWithValues: nodes.map { node in
            let estimatedTextWidth = CGFloat(node.name.count) * 7.2
            let width = min(max(estimatedTextWidth + 48, 88), 160)
            return (node.id, CGSize(width: width, height: 36))
        })
    }

    private func reveal(_ ids: [DependencyNodeID], viewportSize: CGSize) {
        guard !ids.isEmpty else { return }
        let layout = graphLayout(for: store.visibleNodes)
        let frames = ids.compactMap { layout.frames[$0] }
        guard let firstFrame = frames.first else { return }
        let revealRect = frames.dropFirst().reduce(firstFrame) { $0.union($1) }

        withAnimation(.easeOut(duration: 0.25)) {
            offset = DependencyViewport.offsetToReveal(
                contentRect: revealRect,
                viewportSize: viewportSize,
                scale: scale,
                currentOffset: offset,
                margin: 24
            )
        }
    }

    private func resetViewport(
        layout: DependencyGraphLayout,
        viewportSize: CGSize
    ) {
        scale = 1
        guard
            let rootID = store.visibleNodes.first?.id,
            let rootFrame = layout.frames[rootID]
        else {
            offset = .zero
            return
        }

        offset = CGSize(
            width: viewportSize.width / 2 - rootFrame.midX,
            height: 24 - rootFrame.minY
        )
    }
}

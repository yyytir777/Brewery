import SwiftUI

struct DependencyNodeView: View {
    let node: DependencyGraphNode
    let state: DependencyGraphNodeState
    let isSelected: Bool
    let onSelect: () -> Void
    let onNavigate: () -> Void
    let onToggleExpansion: () -> Void
    let onRetry: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            nodeLabel
            stateControl
        }
        .padding(.horizontal, 9)
        .frame(minWidth: 88, maxWidth: 160, minHeight: 36, maxHeight: 36)
        .background {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.12) : Color(nsColor: .controlBackgroundColor))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(
                    isSelected ? Color.accentColor : Color.secondary.opacity(0.35),
                    lineWidth: isSelected ? 2 : 1
                )
        }
        .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .help(node.name)
    }

    private var nodeLabel: some View {
        HStack(spacing: 6) {
            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.tint)
                    .imageScale(.small)
            }

            Text(node.name)
                .font(.system(.caption, design: .rounded, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: onNavigate)
        .simultaneousGesture(TapGesture(count: 1).onEnded(onSelect))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(node.name), dependency level \(node.depth)")
        .accessibilityValue(accessibilityValue)
        .accessibilityAddTraits(
            isSelected ? AccessibilityTraits.isButton.union(.isSelected) : .isButton
        )
        .accessibilityAction(named: Text("Select package"), onSelect)
        .accessibilityAction(named: Text("Open details"), onNavigate)
    }

    @ViewBuilder
    private var stateControl: some View {
        switch state {
        case .collapsed:
            actionButton(
                systemName: "chevron.right",
                help: "Show dependencies",
                action: onToggleExpansion
            )
        case .expanded:
            actionButton(
                systemName: "chevron.down",
                help: "Hide dependencies",
                action: onToggleExpansion
            )
        case .loading:
            ProgressView()
                .controlSize(.mini)
                .accessibilityLabel("Loading dependencies")
        case .failed:
            actionButton(
                systemName: "exclamationmark.triangle.fill",
                help: "Retry loading dependencies",
                foregroundStyle: .orange,
                action: onRetry
            )
        case .cycleReference:
            Image(systemName: "arrow.triangle.2.circlepath")
                .foregroundStyle(.secondary)
                .imageScale(.small)
                .help("This package already appears earlier in this dependency path.")
                .accessibilityLabel("Cycle reference")
        case .leaf:
            EmptyView()
        }
    }

    private func actionButton(
        systemName: String,
        help: String,
        foregroundStyle: Color = .secondary,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .frame(width: 14, height: 14)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(foregroundStyle)
        .help(help)
        .accessibilityLabel(help)
    }

    private var accessibilityValue: String {
        switch state {
        case .collapsed:
            return "Collapsed"
        case .expanded:
            return "Expanded"
        case .loading:
            return "Loading dependencies"
        case .leaf:
            return "No dependencies"
        case .failed(let message):
            return "Loading failed: \(message)"
        case .cycleReference:
            return "Cycle reference"
        }
    }
}

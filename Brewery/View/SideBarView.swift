import SwiftUI

struct SidebarView: View {
    @ObservedObject private var preferences = AppPreferences.shared
    @ObservedObject var vm: BreweryViewModel
    let destination: BreweryDestination
    let onNavigate: (BreweryDestination) -> Void
    @State private var hoveredDestination: BreweryDestination?
    @FocusState private var isSidebarFocused: Bool
    private var selection: Binding<BreweryDestination?> {
        Binding(get: { destination }, set: { if let destination = $0 { onNavigate(destination) } })
    }
    var body: some View {
        List(selection: selection) {
            Label("Home", systemImage: "house").tag(BreweryDestination.home)
                .modifier(rowFeedback(for: .home))
                .accessibilityIdentifier("sidebar.home")
            HStack {
                Label("Installed", systemImage: "shippingbox")
                Spacer()
                if preferences.values.showBadges { Text(vm.installedPackageIDs.count.formatted()).font(.caption).foregroundStyle(.secondary) }
            }.tag(BreweryDestination.installed(outdatedOnly: false))
                .modifier(rowFeedback(for: .installed(outdatedOnly: false)))
                .accessibilityIdentifier("sidebar.installed")
            HStack {
                Label("Updates", systemImage: "arrow.down.circle")
                Spacer()
                if preferences.values.showBadges { Text(vm.hasLoadedOutdated ? vm.outdatedCount.formatted() : "—").font(.caption).foregroundStyle(vm.hasLoadedOutdated && vm.outdatedCount > 0 ? .orange : .secondary) }
            }.tag(BreweryDestination.installed(outdatedOnly: true))
                .modifier(rowFeedback(for: .installed(outdatedOnly: true)))
                .accessibilityIdentifier("sidebar.updates")
            Label("Search", systemImage: "magnifyingglass").tag(BreweryDestination.discover)
                .modifier(rowFeedback(for: .discover))
                .accessibilityIdentifier("sidebar.discover")
        }.listStyle(.sidebar)
            .focused($isSidebarFocused)
            .background {
                SidebarTabNavigation { backwards in
                    guard isSidebarFocused else { return false }
                    let destinations: [BreweryDestination] = [
                        .home, .installed(outdatedOnly: false),
                        .installed(outdatedOnly: true), .discover
                    ]
                    guard let index = destinations.firstIndex(of: destination) else { return false }
                    let next = index + (backwards ? -1 : 1)
                    guard destinations.indices.contains(next) else { return false }
                    onNavigate(destinations[next])
                    return true
                }.frame(width: 0, height: 0)
            }
    }

    private func rowFeedback(for item: BreweryDestination) -> SidebarRowFeedback {
        SidebarRowFeedback(
            isHovered: hoveredDestination == item && destination != item,
            onHover: { hovering in
                if hovering { hoveredDestination = item }
                else if hoveredDestination == item { hoveredDestination = nil }
            }
        )
    }
}

private struct SidebarRowFeedback: ViewModifier {
    let isHovered: Bool
    let onHover: (Bool) -> Void

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .listRowBackground(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isHovered ? Color.primary.opacity(0.08) : Color.clear)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 2)
            )
            .onHover(perform: onHover)
    }
}

// Use AppKit key events to support Tab navigation on macOS 13 as well.
private struct SidebarTabNavigation: NSViewRepresentable {
    let move: (Bool) -> Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.view = view
        context.coordinator.move = move
        context.coordinator.start()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.move = move
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.stop()
    }

    final class Coordinator {
        weak var view: NSView?
        var move: ((Bool) -> Bool)?
        private var monitor: Any?

        func start() {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let window = self.view?.window,
                      window.isKeyWindow, event.window === window,
                      event.keyCode == 48,
                      event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
                      self.move?(event.modifierFlags.contains(.shift)) == true else { return event }
                return nil
            }
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        isolated deinit { stop() }
    }
}

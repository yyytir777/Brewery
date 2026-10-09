import SwiftUI
import Combine
import AppKit
import os

/// Instruments opts into these intervals. Package names and search text are never logged.
nonisolated enum DiscoverPerformance {
    static let log = OSLog(subsystem: "yyytir777.Brewery", category: "DiscoverPerformance")

    static func begin(_ name: StaticString) -> OSSignpostID {
        guard log.signpostsEnabled else { return .invalid }
        let id = OSSignpostID(log: log)
        os_signpost(.begin, log: log, name: name, signpostID: id)
        return id
    }

    static func end(_ name: StaticString, id: OSSignpostID) {
        guard id != .invalid else { return }
        os_signpost(.end, log: log, name: name, signpostID: id)
    }
}

/// Measures an edit through SwiftUI reconciliation to AppKit's next window update.
/// This is not proof of GPU presentation; inspect Animation Hitches separately.
@MainActor
final class DiscoverSearchTrace: ObservableObject {
    private(set) var generation = 0
    private var pending: OSSignpostID?

    func beginEdit() {
        cancel()
        generation += 1
        let id = DiscoverPerformance.begin("QueryToWindowUpdate")
        if id != .invalid { pending = id }
    }

    func windowUpdated(generation: Int) {
        guard generation == self.generation, let id = pending else { return }
        os_signpost(.end, log: DiscoverPerformance.log, name: "QueryToWindowUpdate", signpostID: id, "outcome=updated")
        pending = nil
    }

    func cancel() {
        guard let id = pending else { return }
        os_signpost(.end, log: DiscoverPerformance.log, name: "QueryToWindowUpdate", signpostID: id, "outcome=superseded")
        pending = nil
    }
}

struct DiscoverWindowUpdateProbe: NSViewRepresentable {
    let generation: Int
    let trace: DiscoverSearchTrace

    func makeNSView(context: Context) -> ProbeView { ProbeView() }

    func updateNSView(_ view: ProbeView, context: Context) {
        view.generation = generation
        view.trace = trace
    }

    final class ProbeView: NSView {
        var generation = 0
        weak var trace: DiscoverSearchTrace?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NotificationCenter.default.removeObserver(self, name: NSWindow.didUpdateNotification, object: nil)
            if let window {
                NotificationCenter.default.addObserver(self, selector: #selector(windowUpdated), name: NSWindow.didUpdateNotification, object: window)
            }
        }

        @objc private func windowUpdated() {
            trace?.windowUpdated(generation: generation)
        }
    }
}

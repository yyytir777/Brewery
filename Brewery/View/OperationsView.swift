import SwiftUI

struct OperationsView: View {
    @ObservedObject private var preferences = AppPreferences.shared
    @State private var expandedOutput: [UUID: Bool] = [:]
    @ObservedObject var vm: BreweryViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var selectedID: UUID?
    #if DEBUG
    var completeFixtureOperation: (() -> Void)? = nil

    func fixtureOperationControl(_ action: (() -> Void)?) -> Self {
        var view = self
        view.completeFixtureOperation = action
        return view
    }
    #endif
    private var selected: PackageOperation? {
        vm.operations.first { $0.id == selectedID } ?? vm.activeOperation ?? vm.operations.last
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text("Activity").font(.title2.bold()); Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.cancelAction).accessibilityIdentifier("operations.done") }
            Text("Waiting operations can be cancelled. Running operations finish before the next one starts.")
                .font(.callout).foregroundStyle(.secondary)
            if vm.operations.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "clock").font(.largeTitle).foregroundStyle(.secondary)
                    Text("No operations yet.").foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(alignment: .top, spacing: 16) {
                    List(selection: $selectedID) {
                        ForEach(vm.operations.reversed()) { operation in
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(operation.kind.localizedTitle).lineLimit(2)
                                    Text(LocalizedStringKey(operation.status.rawValue)).font(.caption).foregroundStyle(statusColor(operation.status))
                                        .accessibilityIdentifier("operation.status.\(operation.kind.title)")
                                }
                                Spacer()
                                if operation.status == .running { ProgressView().controlSize(.small) }
                                if operation.status == .queued {
                                    Button { vm.cancelQueuedOperation(operation.id) } label: { Image(systemName: "xmark.circle") }
                                        .buttonStyle(.borderless).help("Cancel waiting operation")
                                        .accessibilityLabel("Cancel \(operation.kind.title)")
                                        .accessibilityIdentifier("operation.cancel.\(operation.kind.title)")
                                }
                            }.tag(operation.id)
                                .accessibilityElement(children: .contain)
                                .accessibilityIdentifier("operation.row.\(operation.kind.title)")
                        }
                    }.frame(width: 240)
                    if let operation = selected {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(operation.kind.localizedTitle).font(.headline)
                            Text(LocalizedStringKey(operation.status.rawValue)).foregroundStyle(statusColor(operation.status))
                            if let started = operation.startedAt { Text("Started \(started.formatted(date: .abbreviated, time: .standard))").font(.caption).foregroundStyle(.secondary) }
                            if let finished = operation.finishedAt { Text("Finished \(finished.formatted(date: .abbreviated, time: .standard))").font(.caption).foregroundStyle(.secondary) }
                            Divider()
                            DisclosureGroup("Command output", isExpanded: Binding(get: {
                                expandedOutput[operation.id] ?? (preferences.values.operationDetails == "always" || operation.status == .failed)
                            }, set: { expandedOutput[operation.id] = $0 })) {
                            ScrollView {
                                (operation.output.isEmpty ? Text("No output yet.") : Text(verbatim: operation.output))
                                    .font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                            }
                            }
                        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    }
                }
            }
            #if DEBUG
            if let completeFixtureOperation {
                Button("Finish Fixture Operation", action: completeFixtureOperation)
                    .accessibilityIdentifier("fixture.completeOperation")
            }
            #endif
        }.padding(20).frame(width: 720, height: 460)
        .onChange(of: selected?.status) { status in
            if status == .failed, let id = selected?.id { expandedOutput[id] = true }
        }
        .onChange(of: preferences.values.operationDetails) { _ in expandedOutput = [:] }
    }

    private func statusColor(_ status: PackageOperation.Status) -> Color {
        switch status {
        case .failed: return .red
        case .succeeded: return .green
        case .running: return .accentColor
        case .queued, .cancelled: return .secondary
        }
    }
}

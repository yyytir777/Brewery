import SwiftUI

struct SettingsView: View {
    @AppStorage(BreweryTelemetry.isEnabledKey) private var isTelemetryEnabled = true
    @State private var logSize: String = ""
    @State private var showClearConfirm = false

    var body: some View {
        Form {
            Section("Logs") {
                LabeledContent("Log file size", value: logSize)

                HStack {
                    Button("Open Log File") {
                        NSWorkspace.shared.open(logFileURL)
                    }
                    Spacer()
                    Button("Clear Log", role: .destructive) {
                        showClearConfirm = true
                    }
                    .tint(.red)
                }
            }

            Section("Privacy") {
                Toggle("Send anonymous usage statistics", isOn: $isTelemetryEnabled)

                Text("Sends an anonymous event when Brewery launches, so I can see how many people use it. It carries no personal data and nothing about your packages — see the Privacy section of the README for the full list. Takes effect on the next launch.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 400)
        .onAppear { refreshSize() }
        .confirmationDialog("Clear log file?", isPresented: $showClearConfirm, titleVisibility: .visible) {
            Button("Clear Log", role: .destructive) {
                try? BreweryLogger.shared.clearLog()
                refreshSize()
            }
        } message: {
            Text("This will permanently delete the log file.")
        }
    }

    private var logFileURL: URL {
        FileManager.default
            .urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/Brewery/Brewery.log")
    }

    private func refreshSize() {
        logSize = BreweryLogger.shared.logFileSize()
    }
}

#Preview {
    SettingsView()
}

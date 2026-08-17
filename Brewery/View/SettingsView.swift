import SwiftUI

struct SettingsView: View {
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

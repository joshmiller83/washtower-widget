import SwiftUI

struct ContentView: View {
    let model: AppModel

    var body: some View {
        NavigationStack {
            Group {
                if model.config == nil {
                    PairingView(model: model)
                } else {
                    StatusList(model: model)
                }
            }
            .navigationTitle("WashTower")
        }
        // `presenting:` hands the link to the buttons. Dismissing clears pendingPairing
        // before a button's action runs, so the action can't read it from the model.
        .alert("Pair with this relay?", isPresented: Binding(
            get: { model.pendingPairing != nil },
            set: { if !$0 { model.pendingPairing = nil } }
        ), presenting: model.pendingPairing) { pairing in
            Button("Pair") { Task { await model.confirmPairing(pairing) } }
            Button("Cancel", role: .cancel) {}
        } message: { pairing in
            Text(pairing.url.host() ?? "")
        }
    }
}

private struct PairingView: View {
    let model: AppModel

    var body: some View {
        ContentUnavailableView {
            Label("Pair with your relay", systemImage: "qrcode.viewfinder")
        } description: {
            Text("On the Mac running the WashTower relay, run deploy/pair.sh, then scan the QR code with the Camera app.")
        } actions: {
            Button("Paste Pairing Link") {
                if let string = UIPasteboard.general.string, let url = URL(string: string) {
                    model.open(url)
                }
            }
            .buttonStyle(.bordered)
            if let error = model.error {
                Text(error).font(.footnote).foregroundStyle(.red)
            }
        }
    }
}

private struct StatusList: View {
    let model: AppModel

    var body: some View {
        List {
            Section {
                if let drums = model.response?.state?.drums, !drums.isEmpty {
                    ForEach(drums) { DrumRow(drum: $0).padding(.vertical, 4) }
                } else if model.response != nil {
                    Text("No washer or dryer reported yet.").foregroundStyle(.secondary)
                } else if model.error == nil {
                    ProgressView()
                }
                if let error = model.error ?? model.response?.error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            } footer: {
                if let updated = model.response?.state?.updatedDate {
                    Text("Updated \(updated, style: .relative) ago")
                }
            }

            Section {
                LiveActivityRow(model: model)
            } header: {
                Text("Live Activity")
            } footer: {
                Text("The relay starts it on your Lock Screen when a cycle begins and ends it when the laundry's done. It also shows on Apple Watch, and in the menu bar of a Mac running macOS 26 with iPhone Mirroring.")
            }

            Section("Relay") {
                LabeledContent("Server", value: model.config?.url.host() ?? "")
                Button("Unpair", role: .destructive) { model.unpair() }
            }
        }
        .refreshable { await model.refresh() }
        .task {
            // Poll while the app is open; the Live Activity covers the rest.
            while !Task.isCancelled {
                await model.refresh()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }
}

private struct LiveActivityRow: View {
    let model: AppModel

    var body: some View {
        if !model.activitiesEnabled {
            Label("Live Activities are turned off for WashTower.", systemImage: "exclamationmark.circle")
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }
        } else if model.hasActivity {
            Label("Showing on your Lock Screen", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Button("End Live Activity", role: .destructive) { Task { await model.endActivity() } }
        } else if model.response?.state?.isActive == true {
            Button("Show on Lock Screen") { Task { await model.startActivity() } }
        } else {
            Label("Waiting for a cycle to start", systemImage: "hourglass")
                .foregroundStyle(.secondary)
        }
    }
}

import SwiftUI

struct SettingsView: View {
    let model: LaundryModel
    @State private var token = ""
    @State private var countryCode = SharedStore.countryCode
    @State private var isSaving = false
    @AppStorage("showCountdownInMenuBar") private var showCountdown = true

    private var countryIsValid: Bool { ThinQRegion.forCountry(countryCode) != nil }
    private var canSave: Bool { countryIsValid && (model.hasToken || !token.isEmpty) && !isSaving }

    var body: some View {
        Form {
            Section {
                SecureField(model.hasToken ? "Paste a new token to replace the saved one" : "Personal access token",
                            text: $token)
                TextField("Country code", text: $countryCode, prompt: Text("US"))
                    .onChange(of: countryCode) { _, new in countryCode = String(new.uppercased().prefix(2)) }
                HStack {
                    if isSaving {
                        ProgressView().controlSize(.small)
                    }
                    Spacer()
                    if model.hasToken {
                        Button("Disconnect", role: .destructive) { model.signOut() }
                    }
                    Button("Save and Test") {
                        isSaving = true
                        Task {
                            await model.save(token: token, countryCode: countryCode)
                            token = ""
                            isSaving = false
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
                }
                status
            } header: {
                Text("LG ThinQ account")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Create a token at [connect-pat.lgthinq.com](https://connect-pat.lgthinq.com), signed in with the account your ThinQ app uses. It only needs \u{201C}view all devices\u{201D} and \u{201C}view all device statuses.\u{201D}")
                    if !countryIsValid {
                        Text("ThinQ Connect doesn't list that country code.").foregroundStyle(.red)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section("Menu bar") {
                Toggle("Show countdown in the menu bar", isOn: $showCountdown)
                Toggle("Open at login", isOn: Binding(
                    get: { model.opensAtLogin },
                    set: { model.setOpensAtLogin($0) }
                ))
            }

            Section("Widget") {
                Text("Right-click the desktop, choose **Edit Widgets…**, and search for **WashTower**. Keep this app running (Open at login) so the widget updates within a minute of a cycle changing.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var status: some View {
        if let error = model.lastError {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        } else if model.hasToken, !model.devices.isEmpty {
            let laundry = model.devices.filter(\.isLaundry)
            Label {
                Text(laundry.isEmpty
                     ? "Connected, but no washer or dryer is on this account."
                     : "Connected: " + laundry.map { "\($0.alias.isEmpty ? $0.model : $0.alias) (\($0.model))" }.joined(separator: ", "))
            } icon: {
                Image(systemName: laundry.isEmpty ? "questionmark.circle" : "checkmark.circle.fill")
                    .foregroundStyle(laundry.isEmpty ? .orange : .green)
            }
        } else if model.hasToken {
            Label("Token saved.", systemImage: "key.fill").foregroundStyle(.secondary)
        }
    }
}

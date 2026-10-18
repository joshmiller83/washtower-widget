import SwiftUI

@main
struct WashTowerWidgetApp: App {
    @State private var model = LaundryModel()

    var body: some Scene {
        MenuBarExtra {
            MenuContentView(model: model)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)

        Window("WashTower Widget Settings", id: "settings") {
            SettingsView(model: model)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }
}

struct MenuBarLabel: View {
    let model: LaundryModel
    @AppStorage("showCountdownInMenuBar") private var showCountdown = true
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        // The label is rebuilt whenever the model's snapshot changes (every poll while running).
        let text = showCountdown ? model.menuBarText(at: Date()) : nil
        Group {
            if let text {
                Label(text, systemImage: "washer")
            } else {
                Image(systemName: "washer")
            }
        }
        .task {
            // First launch: nothing works until there's a token, so go straight to Settings.
            if !model.hasToken {
                openWindow(id: "settings")
                NSApp.activate()
            }
        }
    }
}

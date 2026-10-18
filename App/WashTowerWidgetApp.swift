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
        // Reading model.now re-renders the label as the clock ticks. A Label would be drawn
        // icon-only in the menu bar, so build the image and text separately.
        let text = showCountdown ? model.menuBarText(at: model.now) : nil
        HStack(spacing: 4) {
            Image(systemName: "washer")
            if let text {
                Text(text).monospacedDigit()
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

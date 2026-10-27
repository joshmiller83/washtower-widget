import SwiftUI

@main
struct WashTowerApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Also runs when a push-started Live Activity wakes the app in the background.
        LiveActivityManager.shared.start()
    }

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .onOpenURL { model.open($0) }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        Task {
                            await LiveActivityManager.shared.registerDevice()
                            await model.refresh()
                        }
                    }
                }
                #if DEBUG
                .task {
                    // `-demo-activity` shows the Live Activity with sample data, for the Simulator.
                    // (Activities can only be started while the app is in the foreground.)
                    if ProcessInfo.processInfo.arguments.contains("-demo-activity") {
                        do {
                            try LiveActivityManager.shared.startHere(with: .sample)
                        } catch {
                            print("demo activity failed: \(error)")
                        }
                    }
                }
                #endif
        }
    }
}

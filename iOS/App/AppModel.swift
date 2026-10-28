import ActivityKit
import Foundation
import Observation

@MainActor @Observable
final class AppModel {
    private(set) var config = RelayConfig.load()
    private(set) var response: RelayStateResponse?
    private(set) var error: String?
    private(set) var hasActivity = LiveActivityManager.shared.currentActivity != nil
    /// A pairing link that's been opened but not yet confirmed.
    var pendingPairing: RelayConfig?

    private let activities = LiveActivityManager.shared

    var activitiesEnabled: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }

    func refresh() async {
        hasActivity = activities.currentActivity != nil
        guard let config else { return }
        do {
            response = try await RelayClient(config: config).state()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    func open(_ url: URL) {
        if let pairing = RelayConfig(pairingLink: url) {
            pendingPairing = pairing
        } else {
            error = "That isn't a WashTower pairing link."
        }
    }

    func confirmPairing(_ pairing: RelayConfig) async {
        pendingPairing = nil
        pairing.save()
        config = pairing
        await activities.registerDevice()
        await activities.registerActivities()
        await refresh()
    }

    func unpair() {
        RelayConfig.clear()
        config = nil
        response = nil
        error = nil
    }

    func startActivity() async {
        guard let state = response?.state else { return }
        do {
            try activities.startHere(with: state)
        } catch {
            self.error = "Couldn't start the Live Activity: \(error.localizedDescription)"
        }
        await refresh()
    }

    func endActivity() async {
        await activities.endAll()
        await refresh()
    }
}

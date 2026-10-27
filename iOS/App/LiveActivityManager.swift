import ActivityKit
import UIKit

/// Keeps the relay supplied with the tokens it needs to start and update Live Activities.
///
/// When the relay starts an activity by push, iOS wakes this app in the background;
/// `start()` runs from the App's init, so the new activity's update token is sent
/// to the relay before the app is suspended again.
@MainActor
final class LiveActivityManager {
    static let shared = LiveActivityManager()

    /// A stable id for this phone on the relay.
    let deviceID: String = {
        if let id = UserDefaults.standard.string(forKey: "deviceID") { return id }
        let id = UUID().uuidString.lowercased()
        UserDefaults.standard.set(id, forKey: "deviceID")
        return id
    }()

    private var pushToStartToken: Data?
    private var observed: Set<String> = []
    private var started = false

    var relay: RelayClient? { RelayConfig.load().map(RelayClient.init) }

    var currentActivity: Activity<LaundryActivityAttributes>? {
        Activity<LaundryActivityAttributes>.activities.first { $0.activityState == .active || $0.activityState == .stale }
    }

    func start() {
        guard !started else { return }
        started = true
        Task {
            for await token in Activity<LaundryActivityAttributes>.pushToStartTokenUpdates {
                pushToStartToken = token
                await registerDevice()
            }
        }
        Task {
            for activity in Activity<LaundryActivityAttributes>.activities { observe(activity) }
            for await activity in Activity<LaundryActivityAttributes>.activityUpdates { observe(activity) }
        }
    }

    /// Tells the relay this phone exists, with its latest push-to-start token if it has one.
    func registerDevice() async {
        try? await relay?.registerDevice(id: deviceID, name: UIDevice.current.name, pushToStartToken: pushToStartToken)
    }

    /// Re-sends tokens for activities already running, e.g. right after pairing.
    func registerActivities() async {
        for activity in Activity<LaundryActivityAttributes>.activities {
            if let token = activity.pushToken {
                try? await relay?.registerActivity(deviceID: deviceID, activityID: activity.id, pushToken: token)
            }
        }
    }

    private func observe(_ activity: Activity<LaundryActivityAttributes>) {
        guard observed.insert(activity.id).inserted else { return }
        let activityID = activity.id
        Task {
            for await token in activity.pushTokenUpdates {
                try? await relay?.registerActivity(deviceID: deviceID, activityID: activityID, pushToken: token)
            }
        }
        Task {
            for await state in activity.activityStateUpdates where state == .dismissed || state == .ended {
                try? await relay?.removeActivity(deviceID: deviceID, activityID: activityID)
                observed.remove(activityID)
            }
        }
    }

    /// Starts an activity from the app, for when a cycle is running but the relay's
    /// push-to-start didn't land (or the phone was paired mid-cycle).
    func startHere(with state: LaundryActivityState) throws {
        guard currentActivity == nil else { return }
        let activity = try Activity.request(
            attributes: LaundryActivityAttributes(title: "WashTower"),
            content: ActivityContent(state: state, staleDate: state.staleDate),
            pushType: .token
        )
        observe(activity)
    }

    func endAll() async {
        for activity in Activity<LaundryActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }
}

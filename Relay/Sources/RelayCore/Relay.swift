import Foundation

/// The relay's brain: polls the laundry, decides when to start, update and end the
/// Live Activity, and keeps the phones' tokens. An actor, so the poll loop and the
/// HTTP routes take turns. Every change is saved before the pushes it causes go out,
/// so a restart mid-cycle picks up where it left off instead of starting again.
actor Relay {
    /// Resend content this close to its stale date even if nothing visible changed.
    static let staleMargin: TimeInterval = 5 * 60

    private(set) var state: RelayState
    private let stateFile: StateFile
    private let source: any LaundrySource
    private let sender: (any LiveActivityPushSender)?
    private let composer: PushComposer

    init(state: RelayState, stateFile: StateFile, source: any LaundrySource,
         sender: (any LiveActivityPushSender)?, composer: PushComposer) {
        self.state = state
        self.stateFile = stateFile
        self.source = source
        self.sender = sender
        self.composer = composer
    }

    // MARK: Polling

    /// One poll: read ThinQ and act on what changed. A ThinQ error leaves the session alone.
    func tick(now: Date = Date()) async {
        let snapshot: LaundrySnapshot
        do {
            snapshot = try await source.snapshot()
        } catch {
            let message = error.localizedDescription
            if state.lastError != message { Log.warn("ThinQ: \(message) (retrying every poll)") }
            state.lastError = message
            state.lastPollAt = now
            save()
            return
        }
        await process(LaundryActivityState(snapshot: snapshot), now: now)
    }

    /// The session state machine, given a fresh state.
    func process(_ current: LaundryActivityState, now: Date) async {
        if state.lastError != nil { Log.info("ThinQ is answering again") }
        if current.differsVisibly(from: state.lastState) { Log.info("Laundry: \(describe(current))") }
        state.lastState = current
        state.lastError = nil
        state.lastPollAt = now

        switch (state.session.active, current.isActive) {
        case (false, true): await start(current, now: now)
        case (true, true): await update(current, now: now)
        case (true, false): await end(current, now: now)
        case (false, false): save()
        }
    }

    private func start(_ current: LaundryActivityState, now: Date) async {
        let leftovers = state.session.activities
        state.session = RelaySession(active: true, startedAt: now, lastSent: current, activities: [])
        save()
        let targets = state.devices
            .compactMap { id, device in device.pushToStartToken.map { (deviceId: id, token: $0) } }
            .sorted { $0.deviceId < $1.deviceId }
        Log.info("Cycle started: push-to-start to \(targets.count) device(s)")
        guard let sender else { return Log.info("Pushes are disabled; not sending") }

        // Activities registered between cycles (a late token, a test-start) would sit
        // next to the new one: end them now. The push-to-start replaces them.
        for leftover in leftovers {
            let push = composer.end(current, since: nil, now: now, dismissAt: now)
            report(await sender.send(push, to: leftover.pushToken), "end leftover activity", token: leftover.pushToken)
        }

        let push = composer.start(current, now: now)
        for target in targets {
            let outcome = await sender.send(push, to: target.token)
            report(outcome, "push-to-start \(deviceName(target.deviceId))", token: target.token)
            if case .badToken = outcome, state.devices[target.deviceId]?.pushToStartToken == target.token {
                state.devices[target.deviceId]?.pushToStartToken = nil
            }
        }
        save()
    }

    private func update(_ current: LaundryActivityState, now: Date) async {
        let baseline = state.session.lastSent
        if current.differsVisibly(from: baseline) { state.session.lastSent = current }
        let nowSeconds = now.timeIntervalSince1970
        let due = state.session.activities.filter { activity in
            current.differsVisibly(from: activity.lastSent)
                || activity.staleAt.map { nowSeconds >= $0 - Self.staleMargin } == true
        }
        save()
        guard !due.isEmpty, let sender else { return }

        for activity in due {
            let push = composer.update(current, since: activity.lastSent ?? baseline, now: now)
            let outcome = await sender.send(push, to: activity.pushToken)
            report(outcome, "update (priority \(push.priority)\(push.alert.map { ", \"\($0.title)\"" } ?? ""))", token: activity.pushToken)
            record(outcome, of: push, to: activity)
        }
        save()
    }

    private func end(_ current: LaundryActivityState, now: Date) async {
        let activities = state.session.activities
        let baseline = state.session.lastSent
        state.session = RelaySession()
        save()
        Log.info("Cycle ended: ending \(activities.count) activit\(activities.count == 1 ? "y" : "ies")")
        guard let sender else { return }

        for activity in activities {
            let push = composer.end(current, since: activity.lastSent ?? baseline, now: now)
            report(await sender.send(push, to: activity.pushToken),
                   "end\(push.alert.map { " (\"\($0.title)\")" } ?? "")", token: activity.pushToken)
        }
    }

    // MARK: Phones

    func upsertDevice(id: String, name: String, pushToStartToken: String?, now: Date = Date()) {
        var device = state.devices[id] ?? RelayDevice(name: name, pushToStartToken: nil, updatedAt: now)
        let isNew = state.devices[id] == nil
        device.name = name
        if let pushToStartToken { device.pushToStartToken = pushToStartToken }
        device.updatedAt = now
        state.devices[id] = device
        save()
        if isNew { Log.info("Device registered: \(name)") }
    }

    /// Saves an activity's update token. During a cycle the activity gets the current
    /// state right away: it may have started from older data than the relay has now.
    func registerActivity(deviceId: String, activityId: String, pushToken: String, now: Date = Date()) async {
        state.session.activities.removeAll {
            ($0.deviceId == deviceId && $0.activityId == activityId) || $0.pushToken == pushToken
        }
        let registration = ActivityRegistration(
            deviceId: deviceId, activityId: activityId, pushToken: pushToken, registeredAt: now)
        state.session.activities.append(registration)
        save()
        Log.info("Activity registered on \(deviceName(deviceId))\(state.session.active ? "" : " (between cycles)")")

        guard state.session.active, let current = state.lastState ?? state.session.lastSent, let sender else { return }
        var push = composer.update(current, since: nil, now: now)
        push.alert = nil
        push.priority = current.differsVisibly(from: state.session.lastSent) ? 10 : 5
        let outcome = await sender.send(push, to: pushToken)
        report(outcome, "catch-up update", token: pushToken)
        record(outcome, of: push, to: registration)
        save()
    }

    /// The user dismissed the activity (or it ended on the phone).
    func removeActivity(deviceId: String, activityId: String) {
        let before = state.session.activities.count
        state.session.activities.removeAll { $0.deviceId == deviceId && $0.activityId == activityId }
        if state.session.activities.count != before {
            save()
            Log.info("Activity removed on \(deviceName(deviceId))")
        }
    }

    // MARK: Helpers

    private func record(_ outcome: PushOutcome, of push: LiveActivityPush, to activity: ActivityRegistration) {
        guard let index = state.session.activities.firstIndex(where: {
            $0.deviceId == activity.deviceId && $0.activityId == activity.activityId && $0.pushToken == activity.pushToken
        }) else { return }
        switch outcome {
        case .sent:
            state.session.activities[index].lastSent = push.state
            state.session.activities[index].staleAt = push.staleDate.map(Double.init)
        case .badToken:
            state.session.activities.remove(at: index)
        case .failed:
            break  // Unchanged, so the next poll tries again.
        }
    }

    private func report(_ outcome: PushOutcome, _ what: String, token: String) {
        switch outcome {
        case .sent: Log.info("Sent \(what) to \(token.tokenPrefix)")
        case .badToken(let reason): Log.warn("Dropped token \(token.tokenPrefix) after \(what): \(reason)")
        case .failed(let reason): Log.warn("Couldn't send \(what) to \(token.tokenPrefix): \(reason)")
        }
    }

    private func deviceName(_ id: String) -> String {
        state.devices[id]?.name ?? "device \(id.prefix(8))"
    }

    private func describe(_ laundry: LaundryActivityState) -> String {
        laundry.drums.isEmpty ? "no washer or dryer found"
            : laundry.drums.map { "\($0.name): \(composer.summary($0))" }.joined(separator: "; ")
    }

    private func save() {
        do {
            try stateFile.save(state)
        } catch {
            Log.error("Couldn't save \(stateFile.url.path): \(error)")
        }
    }
}

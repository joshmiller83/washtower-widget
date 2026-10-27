import Foundation

/// The `washtower-relay` command line.
public enum RelayCLI {
    static let usage = """
        usage: washtower-relay <command>

          serve                 run the HTTP API and the 60-second ThinQ poll (what launchd runs)
          pair --url <url>      print a washtower://pair link for the phone (makes the relay key if needed)
          status                devices, session, last state and whether push is on
          poll-once             read ThinQ once and print the Live Activity state as JSON
          test-start            push-to-start a sample activity on every registered phone
          test-end              end the activities the phones registered after test-start

        Settings come from the environment: WT_DATA_DIR (~/WashTowerRelay), WT_HOST (127.0.0.1),
        WT_PORT (8792), WT_THINQ_TOKEN_FILE (~/.config/thinq/pat), WT_COUNTRY (US),
        WT_APNS_KEY_FILE, WT_APNS_KEY_ID, WT_APNS_TEAM_ID, WT_APNS_BUNDLE_ID
        (com.joshmiller83.WashTower), WT_APNS_ENV (development|production),
        WT_DISMISS_AFTER_MINUTES (60).
        """

    struct Failure: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    /// Runs one command and returns the exit status.
    public static func main(_ arguments: [String]) async -> Int32 {
        let config = RelayConfig.fromEnvironment()
        let args = Array(arguments.dropFirst())
        do {
            switch args.first {
            case "serve": try await serve(config)
            case "pair": try pair(config, arguments: Array(args.dropFirst()))
            case "status": try status(config)
            case "poll-once": try await pollOnce(config)
            case "test-start": try await testStart(config)
            case "test-end": try await testEnd(config)
            case "help", "-h", "--help":
                print(usage)
            default:
                FileHandle.standardError.write(Data((usage + "\n").utf8))
                return 2
            }
            return 0
        } catch {
            FileHandle.standardError.write(Data("washtower-relay: \(error.localizedDescription)\n".utf8))
            return 1
        }
    }

    // MARK: serve

    static func serve(_ config: RelayConfig) async throws {
        try FileManager.default.createDirectory(at: config.dataDir, withIntermediateDirectories: true)
        let (key, created) = try RelayKey.ensure(at: config.relayKeyFile)
        if created { Log.info("Made a relay key at \(config.relayKeyFile.path). Pair a phone with `washtower-relay pair --url …`.") }

        let stateFile = StateFile(url: config.stateFile)
        let state = stateFile.loadOrReset()
        let sender = makeSender(config)
        let relay = Relay(
            state: state,
            stateFile: stateFile,
            source: ThinQSource(tokenFile: config.thinqTokenFile, country: config.country, clientIDFile: config.thinqClientIDFile),
            sender: sender,
            composer: composer(config)
        )
        let api = RelayAPI(relay: relay, key: key)
        let server = try HTTPServer(host: config.host, port: config.port) { request in
            let response = await api.handle(request)
            // Reads are frequent and uninteresting; log changes and refusals.
            if request.method != "GET" || response.status >= 400 {
                Log.info("\(request.method) \(request.target) → \(response.status)")
            }
            return response
        }
        let port = try await server.start()
        Log.info("""
            washtower-relay listening on http://\(config.host):\(port); \
            \(state.devices.count) device(s), session \(state.session.active ? "active" : "idle"), \
            polling ThinQ (\(config.country)) every \(config.pollInterval.components.seconds) s
            """)

        while true {
            await relay.tick()
            try await Task.sleep(for: config.pollInterval)
        }
    }

    static func makeSender(_ config: RelayConfig) -> APNsSender? {
        guard let apns = config.apns else {
            Log.warn("Pushes are disabled (\(config.apnsProblem ?? "APNs not configured")). The state API still works.")
            return nil
        }
        do {
            let sender = try APNsSender(config: apns)
            Log.info("APNs on: \(apns.environment.rawValue), key \(apns.keyID), topic \(apns.topic)")
            return sender
        } catch {
            Log.error("Pushes are disabled: \(error.localizedDescription)")
            return nil
        }
    }

    static func composer(_ config: RelayConfig) -> PushComposer {
        PushComposer(timeZone: .current, dismissAfter: TimeInterval(config.dismissAfterMinutes * 60))
    }

    // MARK: pair

    static func pair(_ config: RelayConfig, arguments: [String]) throws {
        var url: String?
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--url", index + 1 < arguments.count {
                url = arguments[index + 1]
                index += 2
            } else if argument.hasPrefix("--url=") {
                url = String(argument.dropFirst("--url=".count))
                index += 1
            } else {
                throw Failure(message: "unexpected argument \(argument)\n\(usage)")
            }
        }
        guard var url, let parsed = URL(string: url), ["https", "http"].contains(parsed.scheme ?? ""), parsed.host != nil else {
            throw Failure(message: "pair needs --url with the relay's public address, e.g. --url https://washtower.example.com")
        }
        while url.hasSuffix("/") { url.removeLast() }
        let (key, created) = try RelayKey.ensure(at: config.relayKeyFile)
        if created {
            FileHandle.standardError.write(Data("Made a new relay key at \(config.relayKeyFile.path)\n".utf8))
        }
        print(RelayKey.pairLink(url: url, key: key))
    }

    // MARK: status

    static func status(_ config: RelayConfig) throws {
        let state = try StateFile(url: config.stateFile).load()
        let composer = composer(config)
        let when = Date.FormatStyle(date: .abbreviated, time: .standard)

        if let apns = config.apns {
            let keyNote = FileManager.default.isReadableFile(atPath: apns.keyFile.path) ? "" : " (key file not readable!)"
            print("APNs:      on, \(apns.environment.rawValue) (\(apns.environment.host.host ?? "")), topic \(apns.topic)\(keyNote)")
        } else {
            print("APNs:      off (\(config.apnsProblem ?? "not configured"))")
        }
        let keyState = (try? RelayKey.load(from: config.relayKeyFile)) == nil ? "missing (run pair)" : "present"
        print("Relay key: \(config.relayKeyFile.path), \(keyState)")
        print("State:     \(config.stateFile.path)")

        let activities = state.session.activities
        print("Devices:   \(state.devices.count)")
        for (id, device) in state.devices.sorted(by: { $0.value.name < $1.value.name }) {
            let count = activities.filter { $0.deviceId == id }.count
            print("  - \(device.name) [\(id.prefix(8))]: push-to-start token \(device.pushToStartToken == nil ? "no" : "yes"), "
                + "\(count) activit\(count == 1 ? "y" : "ies"), updated \(device.updatedAt.formatted(when))")
        }
        let strays = activities.filter { state.devices[$0.deviceId] == nil }.count
        if strays > 0 { print("  - \(strays) activit\(strays == 1 ? "y" : "ies") from unregistered devices") }

        if state.session.active {
            let since = state.session.startedAt.map { " since \($0.formatted(when))" } ?? ""
            print("Session:   active\(since), \(activities.count) activit\(activities.count == 1 ? "y" : "ies")")
        } else {
            let leftovers = activities.isEmpty ? "" : " (\(activities.count) activit\(activities.count == 1 ? "y" : "ies") registered between cycles)"
            print("Session:   idle\(leftovers)")
        }

        print("Last poll: \(state.lastPollAt.map { $0.formatted(when) } ?? "never")")
        if let laundry = state.lastState {
            if laundry.drums.isEmpty { print("Laundry:   no washer or dryer found") }
            for (index, drum) in laundry.drums.enumerated() {
                print("\(index == 0 ? "Laundry:   " : "           ")\(drum.name): \(composer.summary(drum))")
            }
        }
        if let error = state.lastError { print("ThinQ:     \(error)") }
    }

    // MARK: poll-once

    static func pollOnce(_ config: RelayConfig) async throws {
        let source = ThinQSource(tokenFile: config.thinqTokenFile, country: config.country, clientIDFile: config.thinqClientIDFile)
        let state = LaundryActivityState(snapshot: try await source.snapshot())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(decoding: try encoder.encode(state), as: UTF8.self))
    }

    // MARK: test-start / test-end

    static func testStart(_ config: RelayConfig) async throws {
        let sender = try strictSender(config)
        let state = try StateFile(url: config.stateFile).load()
        guard !state.session.active else { throw Failure(message: "A real cycle is running; not sending a test.") }
        let targets = state.devices.filter { $0.value.pushToStartToken != nil }.sorted { $0.value.name < $1.value.name }
        guard !targets.isEmpty else {
            throw Failure(message: "No phone has registered a push-to-start token yet. Pair the phone and open the app first.")
        }
        let push = composer(config).start(.sample, now: Date())
        var sent = 0
        for (_, device) in targets {
            let outcome = await sender.send(push, to: device.pushToStartToken!)
            if outcome == .sent { sent += 1 }
            print("\(device.name): \(describe(outcome))")
        }
        guard sent > 0 else { throw Failure(message: "No push-to-start went through.") }
        print("The phone should show the sample activity and register its update token in a few seconds. End it with test-end.")
    }

    static func testEnd(_ config: RelayConfig) async throws {
        let sender = try strictSender(config)
        let state = try StateFile(url: config.stateFile).load()
        guard !state.session.active else { throw Failure(message: "A real cycle is running; not ending its activities.") }
        let activities = state.session.activities
        guard !activities.isEmpty else {
            throw Failure(message: "No activity has registered an update token. After test-start, the app sends one within a few seconds (check the relay log).")
        }
        // The sample, finished: what a real end looks like, "are done" alert included.
        var final = LaundryActivityState.sample
        for index in final.drums.indices {
            final.drums[index].phase = .finished
            final.drums[index].label = "Done"
            final.drums[index].startedAt = nil
            final.drums[index].endsAt = nil
        }
        final.updatedAt = Date().timeIntervalSince1970
        let push = composer(config).end(final, since: .sample, now: Date())
        var sent = 0
        for activity in activities {
            let outcome = await sender.send(push, to: activity.pushToken)
            if outcome == .sent { sent += 1 }
            print("\(state.devices[activity.deviceId]?.name ?? activity.deviceId) activity \(activity.activityId.prefix(8)): \(describe(outcome))")
        }
        guard sent > 0 else { throw Failure(message: "No end push went through.") }
        print("Ended. The relay forgets these tokens when the next real cycle starts.")
    }

    static func strictSender(_ config: RelayConfig) throws -> APNsSender {
        guard let apns = config.apns else { throw Failure(message: "APNs isn't configured: \(config.apnsProblem ?? "")") }
        return try APNsSender(config: apns)
    }

    static func describe(_ outcome: PushOutcome) -> String {
        switch outcome {
        case .sent: "sent"
        case .badToken(let reason): "token rejected (\(reason)); the phone registers a new one next time the app opens"
        case .failed(let reason): "failed: \(reason)"
        }
    }
}

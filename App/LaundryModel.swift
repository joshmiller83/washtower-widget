import AppKit
import Observation
import ServiceManagement
import WidgetKit

/// Polls ThinQ while the app runs and nudges the widget whenever something visible changes.
@MainActor @Observable
final class LaundryModel {
    private(set) var snapshot: LaundrySnapshot? = SharedStore.snapshot
    private(set) var devices: [ThinQDevice] = SharedStore.cachedDevices(maxAge: .infinity) ?? []
    private(set) var lastError: String?
    private(set) var isRefreshing = false
    private(set) var hasToken = SharedStore.token != nil
    /// Ticks every few seconds so the menu bar countdown moves between polls.
    private(set) var now = Date()

    private var pollTask: Task<Void, Never>?
    private var clockTask: Task<Void, Never>?

    init() {
        startPolling()
        clockTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                self?.now = Date()
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
    }

    /// Every minute while a cycle is going, every two minutes otherwise to catch a new cycle starting.
    private var pollInterval: Duration {
        snapshot?.hasActiveDrum == true ? .seconds(60) : .seconds(120)
    }

    func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                try? await Task.sleep(for: self.pollInterval)
            }
        }
    }

    func refresh() async {
        hasToken = SharedStore.token != nil
        guard hasToken, !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let fresh = try await LaundryService.refresh()
            if fresh.needsWidgetReload(comparedTo: snapshot) {
                WidgetCenter.shared.reloadAllTimelines()
            }
            snapshot = fresh
            devices = SharedStore.cachedDevices(maxAge: .infinity) ?? []
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Saves new settings, then fetches right away so the settings window can show what was found.
    func save(token: String?, countryCode: String) async {
        if let token = token?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty {
            SharedStore.token = token
        }
        SharedStore.countryCode = countryCode
        SharedStore.clearCaches()
        snapshot = nil
        devices = []
        await refresh()
        WidgetCenter.shared.reloadAllTimelines()
        startPolling()
    }

    func signOut() {
        SharedStore.token = nil
        SharedStore.clearCaches()
        snapshot = nil
        devices = []
        hasToken = false
        lastError = nil
        WidgetCenter.shared.reloadAllTimelines()
    }

    // MARK: Menu bar text

    /// e.g. "0:45" for one running drum, "W 0:45  D 1:28" for two.
    func menuBarText(at now: Date) -> String? {
        let running = (snapshot?.drums ?? []).compactMap { drum in
            drum.remainingText(at: now).map { (drum, $0) }
        }
        switch running.count {
        case 0: return nil
        case 1: return running[0].1
        default:
            return running.map { drum, text in "\(drum.kind.defaultName.prefix(1)) \(text)" }
                .joined(separator: "  ")
        }
    }

    // MARK: Open at login

    private(set) var opensAtLogin = SMAppService.mainApp.status == .enabled

    func setOpensAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            lastError = "Couldn't change Open at Login: \(error.localizedDescription)"
        }
        opensAtLogin = SMAppService.mainApp.status == .enabled
    }
}

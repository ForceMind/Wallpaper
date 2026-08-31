import Foundation
import Network

/// Why a change was requested.  The reason is useful for logging and for
/// deciding whether a source refresh is needed by the caller.
enum ChangeTrigger: String {
    case interval
    case daily
    case onLaunch
    case networkRecovery
    case randomWindow
}

/// Schedules local desktop changes.  Fetching/refreshing a wallpaper source is
/// deliberately outside this type: the callback only says that it is time to
/// choose a new image.  This keeps "where to fetch" separate from "when to
/// change the desktop".
final class ChangeScheduler {
    typealias SettingsProvider = () -> AppSettings
    typealias ChangeHandler = (ChangeTrigger) -> Void

    private let settingsProvider: SettingsProvider
    private let changeHandler: ChangeHandler
    private var timer: Timer?
    private var networkMonitor: NWPathMonitor?
    private var networkStateKnown = false
    private var networkWasSatisfied = false
    private var hasStarted = false
    private var didFireOnLaunch = false

    // Date keys are local-calendar dates (rather than elapsed durations), so
    // changing the clock/time zone cannot cause two changes on one local day.
    private var lastDailyKey: String?
    private var lastRandomKey: String?
    private var randomTargetKey: String?
    private var randomTargetMinute: Int?
    private var randomWindowSignature: String?

    init(settingsProvider: @escaping SettingsProvider, changeHandler: @escaping ChangeHandler) {
        self.settingsProvider = settingsProvider
        self.changeHandler = changeHandler
    }

    deinit { stop() }

    /// Starts scheduling. Calling start more than once is harmless.
    func start() {
        if !hasStarted { hasStarted = true }
        reschedule()
    }

    /// Rebuilds timers/monitors after settings or pause state changes. Existing
    /// daily/random de-duplication is retained across reschedules.
    func reschedule() {
        invalidateSources()
        let settings = settingsProvider()
        guard !settings.pauseUpdates else { return }

        switch settings.strategy {
        case .manual:
            return
        case .onLaunch:
            // "On launch" means process launch, not every menu preference
            // change. This avoids an unexpected replacement while editing.
            guard hasStarted, !didFireOnLaunch else { return }
            didFireOnLaunch = true
            request(.onLaunch)
        case .interval:
            let minutes = max(1, settings.intervalMinutes)
            timer = Timer.scheduledTimer(withTimeInterval: TimeInterval(minutes * 60), repeats: true) { [weak self] _ in
                self?.request(.interval)
            }
        case .daily, .randomWindow:
            // A short polling timer is reliable across sleep/wake and clock
            // changes. The date-key checks below guarantee at most one change
            // per local calendar day.
            timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
                self?.checkCalendarTriggers()
            }
            // Handle an app started after the configured time without waiting
            // until tomorrow. This also makes wake-from-sleep deterministic.
            checkCalendarTriggers()
        case .networkChange:
            installNetworkMonitor()
        }
    }

    /// Stops all timers and network observation. State used for daily/random
    /// de-duplication is intentionally retained so pause/resume is safe.
    func stop() {
        invalidateSources()
    }

    private func invalidateSources() {
        timer?.invalidate()
        timer = nil
        networkMonitor?.cancel()
        networkMonitor = nil
        networkStateKnown = false
    }

    private func installNetworkMonitor() {
        let monitor = NWPathMonitor()
        networkMonitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            // NWPathMonitor invokes callbacks on its private queue. Hop to the
            // main run loop before touching scheduler state or invoking UI code.
            DispatchQueue.main.async {
                guard let self else { return }
                let satisfied = path.status == .satisfied
                if !self.networkStateKnown {
                    // Establish a baseline; initial connectivity is not a
                    // recovery event.
                    self.networkStateKnown = true
                    self.networkWasSatisfied = satisfied
                    return
                }
                let recovered = !self.networkWasSatisfied && satisfied
                self.networkWasSatisfied = satisfied
                if recovered && !self.settingsProvider().pauseUpdates {
                    self.request(.networkRecovery)
                }
            }
        }
        monitor.start(queue: DispatchQueue(label: "Wallpaper.NetworkMonitor", qos: .utility))
    }

    private func request(_ trigger: ChangeTrigger) {
        let settings = settingsProvider()
        guard !settings.pauseUpdates else { return }
        // A timer/monitor callback can race with a menu preference change.
        // Ignore callbacks belonging to the strategy that is no longer active.
        let expectedStrategy: UpdateStrategy
        switch trigger {
        case .interval: expectedStrategy = .interval
        case .daily: expectedStrategy = .daily
        case .onLaunch: expectedStrategy = .onLaunch
        case .networkRecovery: expectedStrategy = .networkChange
        case .randomWindow: expectedStrategy = .randomWindow
        }
        guard settings.strategy == expectedStrategy else { return }
        changeHandler(trigger)
    }

    private func checkCalendarTriggers() {
        let settings = settingsProvider()
        guard !settings.pauseUpdates else { return }
        let now = Date()
        let calendar = Calendar.current
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: now)
        guard let hour = components.hour, let minute = components.minute else { return }
        let dayKey = String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
        let minuteOfDay = hour * 60 + minute

        switch settings.strategy {
        case .daily:
            let target = max(0, min(23 * 60 + 59, settings.dailyHour * 60 + settings.dailyMinute))
            guard minuteOfDay >= target, lastDailyKey != dayKey else { return }
            lastDailyKey = dayKey
            request(.daily)
        case .randomWindow:
            let start = max(0, min(23 * 60 + 59, settings.randomStartHour * 60))
            // End is treated as an exclusive clock-minute. If an invalid or
            // equal range is supplied, use the remainder of the day.
            let configuredEnd = max(0, min(24 * 60, settings.randomEndHour * 60))
            let end = configuredEnd > start ? configuredEnd : 24 * 60
            let signature = "\(settings.randomStartHour)-\(settings.randomEndHour)"
            if randomWindowSignature != signature {
                randomWindowSignature = signature
                randomTargetKey = nil
                randomTargetMinute = nil
            }
            if randomTargetKey != dayKey {
                randomTargetKey = dayKey
                randomTargetMinute = Int.random(in: start..<max(start + 1, end))
            }
            guard let target = randomTargetMinute, minuteOfDay >= target, lastRandomKey != dayKey else { return }
            lastRandomKey = dayKey
            request(.randomWindow)
        default:
            return
        }
    }
}

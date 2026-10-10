import ActivityKit
import Combine
import CoreData
import Foundation
import Swinject
import UIKit
import WidgetKit

@available(iOS 16.2, *) private struct ActiveActivity {
    let activity: Activity<LiveActivityAttributes>

    /// Determines if the current activity needs to be recreated.
    ///
    /// - Returns: `true` if the activity is dismissed, ended, stale, or has been active for more than 60 minutes; otherwise,
    /// `false`.
    func needsRecreation() -> Bool {
        switch activity.activityState {
        case .dismissed,
             .ended,
             .stale:
            return true
        case .active:
            break
        @unknown default:
            return true
        }
        return -activity.attributes.startDate.timeIntervalSinceNow > TimeInterval(60 * 60)
    }
}

final class LiveActivityData: ObservableObject {
    /// Determination data used to update live activity state.
    @Published var determination: DeterminationData?
    /// The most recent IoB data
    @Published var iob: Decimal?
    /// Array of glucose readings fetched from persistent storage.
    @Published var glucoseFromPersistence: [GlucoseData]?
    /// The current override data (if any).
    @Published var override: OverrideData?
    /// The current temp target data (if any).
    @Published var tempTarget: TempTargetData?
    /// The widget items displayed within the live activity.
    @Published var widgetItems: [LiveActivityAttributes.LiveActivityItem]?
}

/// A service managing live activity updates and state management.
///
/// This class handles the creation, update, and termination of live activities based on various data sources
/// (e.g. Core Data notifications, glucose updates, settings changes). It integrates with system notifications,
/// dependency injection, and user defaults to ensure that the live activity reflects the current app state.
///
/// Additionally, it supports a restart functionality (via `restartActivityFromLiveActivityIntent()`)
/// via iOS shortcuts, similar to other iOS apps like xDrip4iOS or Sweet Dreams.
@available(iOS 16.2, *) final class LiveActivityManager: Injectable, ObservableObject, SettingsObserver {
    @Injected() private var settingsManager: SettingsManager!
    @Injected() private var broadcaster: Broadcaster!
    @Injected() private var storage: FileStorage!
    @Injected() private var glucoseStorage: GlucoseStorage!
    @Injected() private var iobService: IOBService!

    private let activityAuthorizationInfo = ActivityAuthorizationInfo()
    /// Indicates whether system live activities are enabled.
    @Published private(set) var systemEnabled: Bool

    /// Returns the current Trio settings.
    private var settings: TrioSettings {
        settingsManager.settings
    }

    /// The current active live activity.
    private var currentActivity: ActiveActivity?

    private var data = LiveActivityData()

    /// A dispatch queue for handling Core Data change notifications.
    private let queue = DispatchQueue(label: "LiveActivityBridge.queue", qos: .userInitiated)
    private var coreDataPublisher: AnyPublisher<Set<NSManagedObjectID>, Never>?
    private var subscriptions = Set<AnyCancellable>()

    /// Initializes a new instance of `LiveActivityBridge` and sets up observers, subscribers, and notifications.
    ///
    /// - Parameter resolver: The dependency injection resolver.
    init(resolver: Resolver) {
        coreDataPublisher =
            CoreDataStack.shared.entityChangePublisher
                .receive(on: queue)
                .share()
                .eraseToAnyPublisher()

        systemEnabled = activityAuthorizationInfo.areActivitiesEnabled
        injectServices(resolver)
        setupNotifications()
        registerHandler()
        monitorForLiveActivityAuthorizationChanges()
        broadcaster.register(SettingsObserver.self, observer: self)
        data.objectWillChange.sink { [weak self] in
            Task { @MainActor in
                // by the time this runs, the object change is done, so we see the new data here
                await self?.pushCurrentContent()
            }
        }.store(in: &subscriptions)
        loadInitialData()
    }

    /// Sets up application notifications that trigger live activity updates when the app state changes.
    private func setupNotifications() {
        let notificationCenter = Foundation.NotificationCenter.default
        notificationCenter
            .addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil) { [weak self] _ in
                Task { @MainActor in
                    await self?.pushCurrentContent()
                }
            }
        notificationCenter
            .addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: nil) { [weak self] _ in
                Task { @MainActor in
                    // Custom addition: let the Home Screen widget catch up while refreshes are free.
                    TrioHomeWidgetBridge.reloadNow()
                    await self?.pushCurrentContent()
                }
            }
        notificationCenter.addObserver(
            self,
            selector: #selector(loadWidgetItems),
            name: .liveActivityOrderDidChange,
            object: nil
        )
    }

    /// Called when the app settings change.
    ///
    /// This method triggers an update to the live activity content state based on the new settings.
    /// - Parameter _: The updated `TrioSettings`.
    func settingsDidChange(_: TrioSettings) {
        Task { @MainActor in
            await self.pushCurrentContent()
        }
    }

    /// Registers handlers for Core Data changes related to overrides, glucose readings, and determinations.
    private func registerHandler() {
        coreDataPublisher?.filteredByEntityName("OverrideStored").sink { [weak self] _ in
            Task { await self?.loadOverrides() }
        }.store(in: &subscriptions)

        coreDataPublisher?.filteredByEntityName("TempTargetStored").sink { [weak self] _ in
            Task { await self?.loadTempTarget() }
        }.store(in: &subscriptions)

        coreDataPublisher?.filteredByEntityName("GlucoseStored").sink { [weak self] _ in
            Task { await self?.loadGlucose() }
        }.store(in: &subscriptions)

        coreDataPublisher?.filteredByEntityName("OrefDetermination")
            .debounce(for: .seconds(2), scheduler: DispatchQueue.global(qos: .utility))
            .sink { [weak self] _ in
                Task { await self?.loadDetermination() }
            }.store(in: &subscriptions)

        iobService.iobPublisher
            .debounce(for: .seconds(2), scheduler: DispatchQueue.global(qos: .utility))
            .sink { [weak self] _ in
                self?.data.iob = self?.iobService.currentIOB
            }.store(in: &subscriptions)
    }

    /// Fetches and maps new determination data and updates the live activity content state.
    private func loadDetermination() async {
        do {
            data.determination = try await fetchAndMapDetermination()
        } catch {
            debug(
                .default,
                "[LiveActivityManager] \(DebuggingIdentifiers.failed) failed to fetch and map determination: \(error)"
            )
        }
    }

    /// Fetches and maps override data and updates the live activity content state.
    private func loadOverrides() async {
        do {
            data.override = try await fetchAndMapOverride()
        } catch {
            debug(.default, "[LiveActivityManager] \(DebuggingIdentifiers.failed) failed to fetch and map override: \(error)")
        }
    }

    /// Fetches and maps temp target data and updates the live activity content state.
    private func loadTempTarget() async {
        do {
            data.tempTarget = try await fetchAndMapTempTarget()
        } catch {
            debug(.default, "[LiveActivityManager] \(DebuggingIdentifiers.failed) failed to fetch and map temp target: \(error)")
        }
    }

    /// Handles changes to the live activity order.
    ///
    /// Loads widget items from user defaults and triggers an update to the live activity order.
    @objc private func loadWidgetItems() {
        data.widgetItems = UserDefaults.standard.loadLiveActivityOrderFromUserDefaults() ?? LiveActivityAttributes
            .LiveActivityItem.defaultItems
    }

    /// Sets up the array of glucose data from persistent storage and triggers an update to the live activity.
    private func loadGlucose() async {
        do {
            data.glucoseFromPersistence = try await fetchAndMapGlucose()
        } catch {
            debug(
                .default,
                "[LiveActivityManager] \(DebuggingIdentifiers.failed) failed to fetch glucose with error: \(error)"
            )
        }
    }

    private func loadInitialData() {
        Task {
            await self.loadGlucose()
            await self.loadOverrides()
            await self.loadTempTarget()
            await self.loadDetermination()
            self.loadWidgetItems()
        }
    }

    /// Monitors live activity authorization changes and updates the `systemEnabled` flag.
    private func monitorForLiveActivityAuthorizationChanges() {
        Task {
            for await activityState in activityAuthorizationInfo.activityEnablementUpdates {
                if activityState != systemEnabled {
                    await MainActor.run {
                        systemEnabled = activityState
                    }
                }
            }
        }
    }

    /// Pushes an update to the live activity with the specified content state.
    ///
    /// If an existing activity requires recreation or is outdated, this method ends it and starts a new one.
    /// Otherwise, it updates the current live activity.
    ///
    /// - Parameter state: The new content state to push to the live activity.
    @MainActor private func pushUpdate(_ state: LiveActivityAttributes.ContentState) async {
        if !settings.useLiveActivity || !systemEnabled {
            await endActivity()
            return
        }

        if currentActivity == nil {
            // try to restore an existing activity
            currentActivity = Activity<LiveActivityAttributes>.activities
                .max { $0.attributes.startDate < $1.attributes.startDate }.map {
                    ActiveActivity(activity: $0)
                }

            if let currentActivity {
                debug(.default, "[LiveActivityManager] Restored live activity: \(currentActivity.activity.id)")
            }
        }

        // End all unknown activities except the current one
        for unknownActivity in Activity<LiveActivityAttributes>.activities
            .filter({ self.currentActivity?.activity.id != $0.id })
        {
            await unknownActivity.end(nil, dismissalPolicy: .immediate)
        }

        if let currentActivity {
            if currentActivity.needsRecreation(), UIApplication.shared.applicationState == .active {
                debug(.default, "[LiveActivityManager] Ending current activity for recreation: \(currentActivity.activity.id)")
                await endActivity()
                // After endActivity(), currentActivity is guaranteed to be nil
                // No recursive task, but explicitly restart
                debug(.default, "[LiveActivityManager] Re-pushing update after recreation.")
                await pushUpdate(state)
            } else {
                let content = ActivityContent(
                    state: state,
                    staleDate: min(state.date ?? Date.now, Date.now).addingTimeInterval(360)
                )
                // Before the update, check if currentActivity is still valid
                if let stillCurrent = self.currentActivity, stillCurrent.activity.id == currentActivity.activity.id {
                    debug(.default, "[LiveActivityManager] Updating current activity: \(stillCurrent.activity.id)")
                    await stillCurrent.activity.update(content)
                } else {
                    debug(.default, "[LiveActivityManager] Skipped update: currentActivity changed during pushUpdate.")
                }
            }
        } else {
            // ... Activity is newly created ...
            do {
                let expired = ActivityContent(
                    state: LiveActivityAttributes
                        .ContentState(
                            unit: settings.units.rawValue,
                            bg: "--",
                            direction: nil,
                            change: "--",
                            date: Date.now,
                            highGlucose: settings.high,
                            lowGlucose: settings.low,
                            target: data.determination?.target ?? 100 as Decimal,
                            glucoseColorScheme: settings.glucoseColorScheme.rawValue,
                            useDetailedViewIOS: false,
                            useDetailedViewWatchOS: false,
                            detailedViewState: LiveActivityAttributes.ContentAdditionalState(
                                chart: [],
                                rotationDegrees: 0,
                                cob: 0,
                                iob: 0,
                                tdd: 0,
                                isOverrideActive: false,
                                overrideName: "",
                                overrideDate: Date.now,
                                overrideDuration: 0,
                                overrideTarget: 0,
                                isTempTargetActive: false,
                                tempTargetName: "",
                                tempTargetDate: Date.now,
                                tempTargetDuration: 0,
                                tempTargetTarget: 0,
                                widgetItems: [],
                                minForecast: [],
                                maxForecast: [],
                                forecastLines: [],
                                forecastDisplayType: ForecastDisplayType.cone.rawValue
                            ),
                            isInitialState: true
                        ),
                    staleDate: Date.now.addingTimeInterval(60)
                )

                let activity = try Activity.request(
                    attributes: LiveActivityAttributes(startDate: Date.now),
                    content: expired,
                    pushType: nil
                )
                currentActivity = ActiveActivity(activity: activity)
                debug(.default, "[LiveActivityManager] Created new activity: \(activity.id)")

                // Update the newly created activity with actual data
                let updateContent = ActivityContent(
                    state: state,
                    staleDate: Date.now.addingTimeInterval(5 * 60)
                )
                await activity.update(updateContent)
                debug(.default, "[LiveActivityManager] Set initial content for new activity: \(activity.id)")
            } catch {
                debug(
                    .default,
                    "[LiveActivityManager]: Error creating new activity: \(error)"
                )
                // Reset currentActivity on error to allow retry on next update
                currentActivity = nil
            }
        }
    }

    /// Ends the current live activity and ensures that all unknown activities are terminated.
    private func endActivity() async {
        debug(.default, "[LiveActivityManager] Ending all live activities...")

        if let currentActivity {
            debug(.default, "[LiveActivityManager] Ending current activity: \(currentActivity.activity.id)")
            await currentActivity.activity.end(nil, dismissalPolicy: .immediate)
            self.currentActivity = nil
        }

        for unknownActivity in Activity<LiveActivityAttributes>.activities {
            debug(.default, "[LiveActivityManager] Ending unknown activity: \(unknownActivity.id)")
            await unknownActivity.end(nil, dismissalPolicy: .immediate)
        }

        debug(.default, "[LiveActivityManager] All live activities ended.")
    }

    /// Restarts the live activity from a Live Activity Intent.
    ///
    /// This method mimics xdrip's `restartActivityFromLiveActivityIntent()` behavior by verifying that a valid content state
    /// exists,
    /// ending the current live activity, and starting a new one using the current state.
    @MainActor func restartActivityFromLiveActivityIntent() async {
        await endActivity()

        while (currentActivity != nil && currentActivity!.activity.activityState != .ended) || Activity<LiveActivityAttributes>
            .activities.contains(where: { $0.activityState != .ended })
        {
            debug(.default, "[LiveActivityManager] Waiting for Live Activity to end...")
            try? await Task.sleep(nanoseconds: 200_000_000) // 0.2s sleep
        }

        // Add additional delay to ensure iOS has fully cleaned up the previous activity
        debug(.default, "[LiveActivityManager] Waiting additional time for iOS to clean up...")
        try? await Task.sleep(nanoseconds: 1_000_000_000) // 1s additional delay

        await pushCurrentContent()

        debug(.default, "[LiveActivityManager] Restarted Live Activity from LiveActivityIntent (via iOS Shortcut)")
    }
}

@available(iOS 16.2, *) extension LiveActivityManager {
    @MainActor func pushCurrentContent() async {
        guard let glucose = data.glucoseFromPersistence, let bg = glucose.first else {
            debug(.default, "[LiveActivityManager] pushCurrentContent: no current glucose data available")
            return
        }
        let prevGlucose = data.glucoseFromPersistence?.dropFirst().first

        // Custom addition: keep the Home Screen widget up to date (display only).
        TrioHomeWidgetBridge.publish(
            glucose: glucose,
            determination: data.determination,
            iob: data.iob,
            settings: settings
        )

        guard let determination = data.determination else {
            debug(.default, "[LiveActivityManager] pushCurrentContent: no determination available")
            return
        }

        let content = LiveActivityAttributes.ContentState(
            new: bg,
            prev: prevGlucose,
            units: settings.units,
            chart: glucose,
            settings: settings,
            determination: determination,
            iob: data.iob,
            override: data.override,
            tempTarget: data.tempTarget,
            widgetItems: data.widgetItems
        )

        await pushUpdate(content)
    }
}

// MARK: - Home Screen widget bridge (custom addition, not part of upstream Trio)

/// Copies what Trio already shows (glucose, trend, IOB, COB) into the shared app group
/// so the Home Screen widget can display it. Display only: nothing here reads from or
/// writes to the pump, the CGM or the dosing algorithm.
@MainActor enum TrioHomeWidgetBridge {
    /// Keep the fields in sync with `TrioHomeWidgetSnapshot` in the LiveActivity extension.
    struct Snapshot: Codable, Equatable {
        var glucose: Int
        var glucoseDate: Date
        var previousGlucose: Int?
        var direction: String?
        var units: String
        var low: Double
        var high: Double
        var target: Double?
        var colorScheme: String
        var iob: Double?
        var cob: Int?
        var loopDate: Date?
        var historyDates: [Double]
        var historyValues: [Int]
        var forecastStyle: String?
        var forecastMin: [Int]?
        var forecastMax: [Int]?
        var forecastLines: [ForecastLine]?
    }

    struct ForecastLine: Codable, Equatable {
        var type: String
        var values: [Int]
    }

    private static let kind = "TrioHomeWidget"
    private static let storageKey = "trioHomeWidget.snapshot.v1"
    private static let historyWindow: TimeInterval = 3 * 60 * 60
    private static let maxHistoryPoints = 48
    /// Two hours of forecast at one value every five minutes, plus the starting point.
    private static let maxForecastPoints = 25

    private static var lastPublished: Snapshot?
    private static var pendingReload: Task<Void, Never>?
    private static var lastReload: Date?

    /// iOS allows a widget roughly 40 to 70 refreshes a day while Trio is in the background,
    /// and ignores requests once they are used up. So in the background the widget is
    /// refreshed at most this often while glucose is in range and steady...
    private static let calmReloadInterval: TimeInterval = 20 * 60
    /// ...and with every reading (about every five minutes) when it is low, high or moving fast.
    private static let urgentReloadInterval: TimeInterval = 4 * 60
    /// A change of this many mg/dL from the previous reading counts as moving fast.
    private static let fastChange = 10
    /// The loop result usually lands within half a minute of a new reading. Waiting for it
    /// means one refresh shows both, instead of spending two.
    private static let settleDelay: UInt64 = 30_000_000_000

    /// Refreshes the widget right away. Free while Trio is open, so call it when Trio
    /// comes to the front: the widget then catches up on anything it missed.
    static func reloadNow() {
        pendingReload?.cancel()
        pendingReload = nil
        lastReload = Date()
        WidgetCenter.shared.reloadTimelines(ofKind: kind)
    }

    /// - Parameter glucose: recent readings, newest first.
    static func publish(
        glucose: [GlucoseData],
        determination: DeterminationData?,
        iob: Decimal?,
        settings: TrioSettings
    ) {
        guard let latest = glucose.first,
              let groupID = Bundle.main.object(forInfoDictionaryKey: "AppGroupID") as? String,
              let defaults = UserDefaults(suiteName: groupID)
        else { return }

        // Only offer a delta when the previous reading is close enough in time to mean something.
        var previousGlucose: Int?
        if let previous = glucose.dropFirst().first,
           latest.date.timeIntervalSince(previous.date) <= 15 * 60
        {
            previousGlucose = previous.glucose
        }

        // Last three hours for the chart, thinned to roughly one point every five minutes
        // so sensors that report every minute do not bloat the snapshot.
        let cutoff = latest.date.addingTimeInterval(-historyWindow)
        var historyDates: [Double] = []
        var historyValues: [Int] = []
        var lastKept: Date?
        for reading in glucose {
            if reading.date < cutoff || historyDates.count >= maxHistoryPoints { break }
            if let lastKept, lastKept.timeIntervalSince(reading.date) < 4 * 60 { continue }
            historyDates.append(reading.date.timeIntervalSince1970)
            historyValues.append(reading.glucose)
            lastKept = reading.date
        }

        let snapshot = Snapshot(
            glucose: latest.glucose,
            glucoseDate: latest.date,
            previousGlucose: previousGlucose,
            direction: latest.direction?.symbol,
            units: settings.units.rawValue,
            low: NSDecimalNumber(decimal: settings.low).doubleValue,
            high: NSDecimalNumber(decimal: settings.high).doubleValue,
            // Trio reports 0 when there is no current target; let the widget use its default instead.
            target: determination.flatMap { $0.target > 0 ? NSDecimalNumber(decimal: $0.target).doubleValue : nil },
            colorScheme: settings.glucoseColorScheme.rawValue,
            iob: iob.map { (NSDecimalNumber(decimal: $0).doubleValue * 100).rounded() / 100 },
            cob: determination?.cob,
            loopDate: determination?.date,
            historyDates: historyDates,
            historyValues: historyValues,
            forecastStyle: determination == nil ? nil : settings.forecastDisplayType.rawValue,
            forecastMin: determination.map { Array($0.minForecast.prefix(maxForecastPoints)) },
            forecastMax: determination.map { Array($0.maxForecast.prefix(maxForecastPoints)) },
            forecastLines: determination.map {
                $0.forecastLines.map { ForecastLine(type: $0.type, values: Array($0.values.prefix(maxForecastPoints))) }
            }
        )

        // Nothing new to show: do not spend one of the widget refreshes iOS allows per day.
        guard snapshot != lastPublished else { return }
        guard let encoded = try? JSONEncoder().encode(snapshot) else { return }

        let isNewReading = lastPublished?.glucoseDate != snapshot.glucoseDate
            || lastPublished?.glucose != snapshot.glucose
        defaults.set(encoded, forKey: storageKey)
        lastPublished = snapshot

        // While Trio is open, refreshes are free: show every change straight away.
        if UIApplication.shared.applicationState == .active {
            reloadNow()
            return
        }

        // In the background only a new reading can trigger a refresh. Changes to IOB, COB
        // or the loop on their own wait for the next reading.
        guard isNewReading, pendingReload == nil else { return }
        pendingReload = Task { @MainActor in
            try? await Task.sleep(nanoseconds: settleDelay)
            guard !Task.isCancelled else { return }
            pendingReload = nil
            guard let current = lastPublished else { return }

            let interval = needsAttention(current) ? urgentReloadInterval : calmReloadInterval
            if let lastReload, Date().timeIntervalSince(lastReload) < interval { return }
            reloadNow()
        }
    }

    /// Low, high or changing fast: worth spending a refresh on every reading.
    private static func needsAttention(_ snapshot: Snapshot) -> Bool {
        let glucose = Double(snapshot.glucose)
        if glucose < snapshot.low || glucose > snapshot.high { return true }
        if let previous = snapshot.previousGlucose, abs(snapshot.glucose - previous) >= fastChange { return true }
        return false
    }
}

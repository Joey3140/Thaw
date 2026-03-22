//
//  AppLifecycleTracker.swift
//  Project: Thaw
//
//  Copyright (Ice) © 2023–2025 Jordan Baird
//  Copyright (Thaw) © 2026 Toni Förster
//  Licensed under the GNU GPLv3

import Cocoa
import Combine

/// Tracks the lifecycle state of menu bar item apps to coordinate restoration.
///
/// This prevents attempting to restore positions while an app is still
/// launching or loading its menu bar items, which can cause shuffling
/// and incorrect placements.
@MainActor
final class AppLifecycleTracker {
    /// The lifecycle state of an app.
    enum AppState {
        /// App is not currently running.
        case notRunning

        /// App just launched (within last 5 seconds).
        case launching

        /// App is loading menu bar items (item count changing).
        case loadingItems(startTime: Date, lastItemCount: Int)

        /// App has stable menu bar items (no changes for 3+ seconds).
        case stable(since: Date)

        /// App is terminating.
        case terminating

        var isTransitioning: Bool {
            switch self {
            case .launching, .loadingItems, .terminating:
                return true
            case .notRunning, .stable:
                return false
            }
        }

        var canRestore: Bool {
            if case .stable = self { return true }
            return false
        }
    }

    /// Maps bundle IDs to their current lifecycle state.
    private var appStates: [String: AppState] = [:]

    /// Tracks item counts per app for detecting loading state.
    private var itemCounts: [String: [Int]] = [:]

    /// Timestamp when each app was first seen.
    private var firstSeen: [String: Date] = [:]

    /// Time required in loadingItems state before considering stable.
    private let stableThreshold: TimeInterval = 3.0

    /// Time after launch before transitioning from launching to loadingItems.
    private let launchGracePeriod: TimeInterval = 5.0

    /// Number of consecutive cache cycles with same item count to consider stable.
    private let requiredStableObservations = 3

    private var cancellables = Set<AnyCancellable>()
    private let diagLog = DiagLog(category: "AppLifecycleTracker")

    init() {
        setupWorkspaceNotifications()
    }

    /// Sets up notifications for app launch/termination.
    private func setupWorkspaceNotifications() {
        NSWorkspace.shared.notificationCenter.publisher(
            for: NSWorkspace.didLaunchApplicationNotification
        )
        .compactMap { $0.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication }
        .compactMap { $0.bundleIdentifier }
        .sink { [weak self] bundleID in
            self?.appLaunched(bundleID)
        }
        .store(in: &cancellables)

        NSWorkspace.shared.notificationCenter.publisher(
            for: NSWorkspace.didTerminateApplicationNotification
        )
        .compactMap { $0.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication }
        .compactMap { $0.bundleIdentifier }
        .sink { [weak self] bundleID in
            self?.appTerminated(bundleID)
        }
        .store(in: &cancellables)
    }

    /// Called when an app launches.
    private func appLaunched(_ bundleID: String) {
        appStates[bundleID] = .launching
        firstSeen[bundleID] = Date()
        itemCounts[bundleID] = []
        diagLog.debug("App launched: \(bundleID)")
    }

    /// Called when an app terminates.
    private func appTerminated(_ bundleID: String) {
        appStates[bundleID] = .terminating

        // Clean up after a delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.appStates.removeValue(forKey: bundleID)
            self?.itemCounts.removeValue(forKey: bundleID)
            self?.firstSeen.removeValue(forKey: bundleID)
        }

        diagLog.debug("App terminated: \(bundleID)")
    }

    /// Updates the state of apps based on current items.
    ///
    /// - Parameter items: All current menu bar items
    func update(with items: [MenuBarItem]) {
        // Group items by bundle ID
        var itemsByBundle: [String: [MenuBarItem]] = [:]
        for item in items where !item.isControlItem {
            let bundleID = item.tag.namespace.description
            if bundleID.contains(".") {
                itemsByBundle[bundleID, default: []].append(item)
            }
        }

        let now = Date()

        for (bundleID, appItems) in itemsByBundle {
            let currentCount = appItems.count
            var counts = itemCounts[bundleID, default: []]
            counts.append(currentCount)

            // Keep only recent observations
            if counts.count > requiredStableObservations {
                counts.removeFirst()
            }
            itemCounts[bundleID] = counts

            // Determine state transitions
            switch appStates[bundleID] ?? .notRunning {
            case .notRunning:
                // App appeared without us seeing launch - might be Thaw startup
                appStates[bundleID] = .launching
                firstSeen[bundleID] = now

            case .launching:
                if let firstSeenTime = firstSeen[bundleID],
                   now.timeIntervalSince(firstSeenTime) > launchGracePeriod
                {
                    appStates[bundleID] = .loadingItems(
                        startTime: firstSeenTime,
                        lastItemCount: currentCount
                    )
                    diagLog.debug("App \(bundleID) entering loadingItems phase")
                }

            case .loadingItems:
                // Check if item count has stabilized
                if counts.count >= requiredStableObservations,
                   counts.allSatisfy({ $0 == currentCount })
                {
                    appStates[bundleID] = .stable(since: now)
                    diagLog.debug("App \(bundleID) is now stable with \(currentCount) items")
                }

            case .stable:
                // Check if items changed (app updated its menu bar)
                if counts.count >= requiredStableObservations,
                   !counts.allSatisfy({ $0 == currentCount })
                {
                    appStates[bundleID] = .loadingItems(
                        startTime: now,
                        lastItemCount: counts.first ?? currentCount
                    )
                    diagLog.debug("App \(bundleID) items changed, re-entering loadingItems")
                }

            case .terminating:
                // App reappeared - treat as new launch
                appStates[bundleID] = .launching
                firstSeen[bundleID] = now
            }
        }

        // Mark apps that disappeared as not running
        let currentBundles = Set(itemsByBundle.keys)
        for bundleID in appStates.keys where !currentBundles.contains(bundleID) {
            if case .terminating = appStates[bundleID] { continue }
            appStates[bundleID] = .notRunning
        }
    }

    /// Returns true if we should wait before restoring positions for the given app.
    ///
    /// - Parameter bundleID: The app's bundle identifier
    /// - Returns: True if restoration should be deferred
    func shouldDeferRestoration(for bundleID: String) -> Bool {
        guard let state = appStates[bundleID] else { return false }
        return state.isTransitioning
    }

    /// Returns true if any relevant apps are currently transitioning.
    ///
    /// - Parameter itemIdentifiers: Identifiers of items we're considering restoring
    /// - Returns: True if restoration should be deferred
    func shouldDeferRestoration(for itemIdentifiers: [String]) -> Bool {
        for identifier in itemIdentifiers {
            // Extract bundle ID from identifier (format: "bundleID:title:instanceIndex")
            let components = identifier.split(separator: ":", maxSplits: 1)
            guard let bundleID = components.first.map(String.init) else { continue }

            if shouldDeferRestoration(for: bundleID) {
                diagLog.debug("Deferring restoration for \(bundleID) - app is transitioning")
                return true
            }
        }
        return false
    }

    /// Returns true if the app is ready for position restoration.
    ///
    /// - Parameter bundleID: The app's bundle identifier
    /// - Returns: True if restoration can proceed
    func isReadyForRestoration(for bundleID: String) -> Bool {
        guard let state = appStates[bundleID] else { return true }
        return state.canRestore
    }

    /// Returns the current state of an app for debugging.
    func state(for bundleID: String) -> AppState {
        appStates[bundleID] ?? .notRunning
    }

    /// Returns all apps currently in a specific state.
    func apps(in state: AppState) -> [String] {
        appStates.compactMap { bundleID, appState in
            switch (state, appState) {
            case (.launching, .launching),
                 (.terminating, .terminating),
                 (.notRunning, .notRunning):
                return bundleID
            case (.loadingItems, .loadingItems),
                 (.stable, .stable):
                return bundleID
            default:
                return nil
            }
        }
    }

    /// Returns the count of apps currently in transitioning states.
    var transitioningAppsCount: Int {
        appStates.values.filter { $0.isTransitioning }.count
    }

    /// Resets all tracked states.
    func reset() {
        appStates.removeAll()
        itemCounts.removeAll()
        firstSeen.removeAll()
        diagLog.info("Reset all app lifecycle states")
    }
}
